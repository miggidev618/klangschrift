import KlangschriftCore
import Foundation
import KlangschriftDesktopModelCatalog
import KlangschriftDesktopModels
import KlangschriftDesktopNativeModels

/// Persisted separately from the legacy MLX preferences. This actor never
/// reads model caches and stores only an additive desktop selection plus up to
/// two favourites.
public protocol DesktopModelSettingsStoring: Sendable {
    func load() async -> DesktopModelSettings
    func save(_ settings: DesktopModelSettings) async
}

public actor DesktopModelUserDefaultsStore: DesktopModelSettingsStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "io.github.miggidev618.klangschrift.desktop-model-settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> DesktopModelSettings {
        guard let data = defaults.data(forKey: key), let settings = try? JSONDecoder().decode(DesktopModelSettings.self, from: data) else {
            return .init()
        }
        return settings
    }

    public func save(_ settings: DesktopModelSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum DesktopModelProductError: Error, Sendable, Equatable {
    case unknownModel
    case notInstalled
    case unsuitableOS
    case installationInProgress
}

/// The sole presentation-safe install state. A terminal cancellation is only
/// published after the installer has returned and removed its private staging.
public enum DesktopModelInstallationStatus: Sendable, Equatable {
    case idle
    case running(DesktopModelInstallationProgress)
    case cancelling(modelID: String)
    case cancelled(modelID: String)
    case failed(modelID: String, message: String)
}

/// A presentation-safe explanation for a product action. Internal SDK pin,
/// worker and manifest diagnostics deliberately never reach this type.
public enum DesktopModelProductMessage {
    public static func unavailable(for error: DesktopModelProductError, model: DesktopModel? = nil) -> String {
        switch error {
        case .unknownModel: return "Dieses Modell ist nicht verfügbar."
        case .notInstalled: return "Dieses Modell ist noch nicht installiert."
        case .unsuitableOS:
            let version = model?.minimumMacOS ?? 14
            return "Dieses Modell benötigt mindestens macOS \(version)."
        case .installationInProgress: return "Eine Modellinstallation läuft bereits."
        }
    }
}

/// Product-safe caller guidance for the selected desktop transcription model.
/// This preserves the actionable missing-model distinction without exposing
/// manifests, SDK diagnostics, worker paths or any fallback route.
public enum DesktopModelTranscriptionAction: Sendable, Equatable {
    case selectModel(message: String)
    case installSelectedModel(modelID: String, message: String)
    case ready
}

/// Product-level bridge for the AP04 catalogue. It owns the concrete
/// installer/runtime path, scheduler policy and additive settings state, but
/// not a microphone, event tap, app lifecycle or network preload.
public actor DesktopModelProductService {
    public typealias InstallationInspector = @Sendable (DesktopModelInstallManifest) async -> Bool
    public typealias ExplicitInstaller = @Sendable (DesktopModelInstallManifest) async throws -> Void
    public typealias ProgressingExplicitInstaller = @Sendable (DesktopModelInstallManifest, @escaping @Sendable (DesktopModelInstallationProgress) async -> Void) async throws -> Void
    public typealias RuntimeFactory = DesktopRuntimeCoordinator.Factory

    private let manifests: [String: DesktopModelInstallManifest]
    private let settingsStore: any DesktopModelSettingsStoring
    private let isInstalled: InstallationInspector
    private let explicitInstall: ExplicitInstaller
    private let progressingInstall: ProgressingExplicitInstaller?
    private let osSupports: @Sendable (Int) -> Bool
    private let coordinator: DesktopRuntimeCoordinator
    private let scheduler: DesktopResidentScheduler
    private let residentCosts: [String: Int]
    private let memoryBudgetBytes: Int
    private var settings: DesktopModelSettings = .init()
    private var installed = Set<String>()
    private var invalidated = false
    private var activeInstall: (admissionID: UUID, modelID: String, task: Task<Void, Error>)?
    private var installationStatus: DesktopModelInstallationStatus = .idle

    /// The caller supplies only fixed manifests and concrete local runtime
    /// construction. There is no fallback downloader or cache discovery path.
    public init(
        manifests: [String: DesktopModelInstallManifest],
        settingsStore: any DesktopModelSettingsStoring,
        residentCosts: [String: Int] = [:],
        memoryBudgetBytes: Int = 0,
        osSupports: @escaping @Sendable (Int) -> Bool = { required in
            ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: required, minorVersion: 0, patchVersion: 0))
        },
        installationInspector: @escaping InstallationInspector,
        explicitInstaller: @escaping ExplicitInstaller,
        progressingInstaller: ProgressingExplicitInstaller? = nil,
        runtimeFactory: @escaping RuntimeFactory
    ) {
        self.manifests = manifests
        self.settingsStore = settingsStore
        self.residentCosts = residentCosts
        self.memoryBudgetBytes = memoryBudgetBytes
        self.osSupports = osSupports
        self.isInstalled = installationInspector
        self.explicitInstall = explicitInstaller
        self.progressingInstall = progressingInstaller
        self.coordinator = DesktopRuntimeCoordinator(factory: runtimeFactory)
        self.scheduler = DesktopResidentScheduler(coordinator: coordinator)
    }

    /// Builds the real AP04 path: fixed manifest validation before a bounded
    /// local native worker is constructed. The caller must provide a bundled
    /// worker URL in AP07; this method never searches PATH or a user cache.
    public static func production(
        manifestSourceURL: URL,
        installerRoot: URL,
        workerURL: URL,
        settingsStore: any DesktopModelSettingsStoring = DesktopModelUserDefaultsStore(),
        residentCosts: [String: Int] = [:],
        memoryBudgetBytes: Int = 0
    ) throws -> DesktopModelProductService {
        let manifests = try DesktopModelInstallCatalog.manifests(from: manifestSourceURL)
        let installer = DesktopModelInstaller(root: installerRoot)
        let factory: RuntimeFactory = { modelID in
            guard let manifest = manifests[modelID] else { throw DesktopRuntimeError.unavailable }
            return DesktopBoundedWorkerModel(configuration: .init(executableURL: workerURL, modelManifest: manifest, installerRoot: installerRoot))
        }
        return .init(
            manifests: manifests,
            settingsStore: settingsStore,
            residentCosts: residentCosts,
            memoryBudgetBytes: memoryBudgetBytes,
            installationInspector: { manifest in await installer.isInstalled(manifest) },
            explicitInstaller: { manifest in _ = try await installer.install(manifest) },
            progressingInstaller: { manifest, progress in _ = try await installer.install(manifest, progress: progress) },
            runtimeFactory: factory
        )
    }

    /// Loads separate desktop preferences, validates the currently installed
    /// fixed manifests, then starts selected-first local preload policy.
    public func start() async {
        guard !invalidated else { return }
        let loadedSettings = await settingsStore.load()
        guard !invalidated else { return }
        settings = loadedSettings
        await refreshInstalled()
        guard !invalidated else { return }
        await synchronizeScheduler()
        guard !invalidated else { return }
        await scheduler.appStarted()
    }

    public func modelItems(language: String? = nil, installedOnly: Bool = false) -> [DesktopModelListItem] {
        DesktopModelList.items(language: language, installedOnly: installedOnly, settings: settings, installed: installed)
    }

    public func currentSettings() -> DesktopModelSettings { settings }
    /// `nil` means only that this additive desktop preference has no choice.
    /// It never consults or alters the separate legacy MLX preference.
    public func selectedModelID() -> String? { settings.selectedModelID }
    public func installedModelIDs() -> Set<String> { installed }
    public func currentInstallationStatus() -> DesktopModelInstallationStatus { installationStatus }
    public func statistics(for modelID: String) async -> DesktopModelRuntimeStats { await coordinator.statistics(for: modelID) }
    public func residentState(for modelID: String) async -> DesktopResidentState { await coordinator.residentState(for: modelID) }
    /// Redacted R3 diagnostic only. Presentation-safe action messages remain
    /// unchanged and never expose this worker-level evidence.
    public func nativeFailureDiagnostic(for modelID: String) async -> DesktopNativeFailureDiagnostic? {
        await coordinator.nativeFailureDiagnostic(for: modelID)
    }

    public func actionMessage(for modelID: String) -> String? {
        guard let model = model(for: modelID) else { return DesktopModelProductMessage.unavailable(for: .unknownModel) }
        guard osSupports(model.minimumMacOS) else { return DesktopModelProductMessage.unavailable(for: .unsuitableOS, model: model) }
        guard installed.contains(modelID) else { return DesktopModelProductMessage.unavailable(for: .notInstalled, model: model) }
        return nil
    }

    public func transcriptionAction() -> DesktopModelTranscriptionAction {
        guard let modelID = settings.defaultModelID else {
            return .selectModel(message: "Wähle zuerst ein installiertes Modell aus.")
        }
        guard let model = model(for: modelID) else {
            return .selectModel(message: DesktopModelProductMessage.unavailable(for: .unknownModel))
        }
        guard osSupports(model.minimumMacOS) else {
            return .selectModel(message: DesktopModelProductMessage.unavailable(for: .unsuitableOS, model: model))
        }
        guard installed.contains(modelID) else {
            return .installSelectedModel(modelID: modelID, message: DesktopModelProductMessage.unavailable(for: .notInstalled, model: model))
        }
        return .ready
    }

    /// The only product download entry point. Calling `start`, filtering,
    /// selection, preload and transcription cannot reach this closure.
    public func install(modelID: String) async throws {
        guard !invalidated else { throw CancellationError() }
        let model = try requireCompatibleModel(modelID)
        guard let manifest = manifests[model.id] else { throw DesktopModelProductError.unknownModel }
        guard activeInstall == nil else { throw DesktopModelProductError.installationInProgress }
        installationStatus = .running(.init(modelID: model.id, phase: .downloading, completedBytes: 0, totalBytes: manifest.totalBytes, completedFiles: 0, totalFiles: manifest.sourceFiles.count))
        let explicitInstall = self.explicitInstall
        let progressingInstall = self.progressingInstall
        let service = self
        let task = Task {
            if let progressingInstall {
                try await progressingInstall(manifest) { progress in await service.recordInstallProgress(progress) }
            } else {
                try await explicitInstall(manifest)
            }
        }
        let admissionID = UUID()
        activeInstall = (admissionID, model.id, task)
        let result = await task.result
        await finishInstall(admissionID: admissionID, modelID: model.id, result: result)
        try result.get()
    }

    /// Global serialization means only the admitted model can be cancelled.
    /// `true` says a cancellation signal reached its task, not that cleanup is
    /// complete; observe status until the terminal `.cancelled` state.
    public func cancelInstall(modelID: String) -> Bool {
        guard let activeInstall, activeInstall.modelID == modelID else { return false }
        installationStatus = .cancelling(modelID: modelID)
        activeInstall.task.cancel()
        return true
    }

    public func selectDefault(modelID: String) async throws {
        _ = try requireInstalledModel(modelID)
        settings.select(modelID)
        await persistAndSynchronize()
    }

    /// The only explicit route back to the pre-existing legacy standard. It
    /// clears no legacy data or preference. If a desktop preload cannot prove
    /// its reader ended, this throws and deliberately preserves the selected
    /// desktop ID both in memory and persistence.
    public func clearDesktopSelection() async throws {
        guard settings.selectedModelID != nil else { return }
        try await scheduler.clearSelectedDesktopDemand()
        settings.selectedModelID = nil
        await persistAndSynchronize()
    }

    /// Semantic alias used by root: legacy selection is an explicit desktop
    /// selection clear, not a fallback from any desktop error.
    public func selectLegacyStandard() async throws {
        try await clearDesktopSelection()
    }

    public func setFavorites(_ modelIDs: [String]) async throws {
        let unique = Array(NSOrderedSet(array: modelIDs).compactMap { $0 as? String }.prefix(2))
        for id in unique { _ = try requireInstalledModel(id) }
        settings.setFavorites(unique)
        await persistAndSynchronize()
    }

    public func prepareSelected() async throws {
        guard let modelID = settings.defaultModelID else { throw DesktopModelProductError.notInstalled }
        _ = try requireInstalledModel(modelID)
        try await scheduler.demandPrepare(modelID: modelID)
    }

    /// Explicit no-audio Phonon first preparation. The product does not call
    /// this from `start`, preload or transcription; its native contract is
    /// restricted to the two pinned local Phonon manifests.
    public func preparePhononFirstUse(modelID: String) async throws {
        let model = try requireInstalledModel(modelID)
        guard manifests[model.id].map(DesktopPhononFirstPrepareContract.permits) == true else {
            throw DesktopModelProductError.unknownModel
        }
        try await scheduler.preparePhononFirstUse(modelID: modelID)
    }

    /// Selection is looked up before the first await and passed as an explicit
    /// ID to the serial scheduler; a later settings change cannot affect this
    /// live demand.
    public func transcribeSelected(audioFile: URL, language: DesktopDictationLanguage = .automatic, preferredLanguages: [String] = PreferredDictationLanguages.defaults, recognitionHintPrompt: String? = nil) async throws -> String {
        guard let modelID = settings.defaultModelID else { throw DesktopModelProductError.notInstalled }
        _ = try requireInstalledModel(modelID)
        return try await scheduler.transcribe(modelID: modelID, audioFile: audioFile, language: language, preferredLanguages: preferredLanguages, recognitionHintPrompt: recognitionHintPrompt)
    }

    public func retryPrepare(modelID: String) async throws {
        _ = try requireInstalledModel(modelID)
        try await scheduler.demandPrepare(modelID: modelID)
    }

    /// Root uses this exact outcome to gate WAV cleanup. A successful
    /// transcription is already a file-reader completion, while a resident
    /// worker may deliberately remain warm after it returns.
    public func cancelDemand() async -> DesktopModelDemandCancellationOutcome {
        await scheduler.cancelDemand()
    }
    public func memoryPressure() async { await scheduler.memoryPressure() }

    /// The graph owns this explicit lifecycle boundary. It invalidates an
    /// in-flight cold start before it can publish scheduler work, then waits
    /// for the existing demand/preload reap contracts rather than replacing an
    /// unknown native owner.
    public private(set) var terminalDrainConfirmed = false

    public func invalidateAndDrain() async {
        invalidated = true
        let drainingInstall = activeInstall
        if let drainingInstall {
            installationStatus = .cancelling(modelID: drainingInstall.modelID)
            drainingInstall.task.cancel()
        }
        terminalDrainConfirmed = await scheduler.terminalDrain()
        if let drainingInstall {
            let result = await drainingInstall.task.result
            await finishInstall(admissionID: drainingInstall.admissionID, modelID: drainingInstall.modelID, result: result)
        }
    }

    /// Internal test observation for deterministic public-port races. It
    /// reveals no worker, file, audio or runtime diagnostics.
    func firstPurposeReservationJoinCount() async -> Int {
        await scheduler.firstPurposeReservationJoinCount()
    }

    /// Internal test synchronization for the public no-audio product port.
    /// It carries no model, worker, audio or SDK diagnostic data.
    func waitForFirstPurposeReservationJoinCount(atLeast minimum: Int, timeout: Duration) async throws {
        try await scheduler.waitForFirstPurposeReservationJoinCount(atLeast: minimum, timeout: timeout)
    }

    /// Internal test synchronization for the shared preload-reap dependency.
    /// It exposes no native worker, model file or audio diagnostics.
    func waitForPreloadTeardownWaiterCount(atLeast minimum: Int, timeout: Duration) async throws {
        try await scheduler.waitForPreloadTeardownWaiterCount(atLeast: minimum, timeout: timeout)
    }

    private func refreshInstalled() async {
        var result = Set<String>()
        for (id, manifest) in manifests where await isInstalled(manifest) { result.insert(id) }
        installed = result
    }

    private func recordInstallProgress(_ progress: DesktopModelInstallationProgress) {
        guard activeInstall?.modelID == progress.modelID else { return }
        guard case .running = installationStatus else { return }
        installationStatus = .running(progress)
    }

    /// Exactly one observer commits the terminal state for an admitted task.
    /// Both the public install caller and lifecycle invalidation await the
    /// actual installer task, whose return is after private staging cleanup.
    /// A cancellation is published only when that task truly reports one.
    private func finishInstall(
        admissionID: UUID,
        modelID: String,
        result: Result<Void, Error>
    ) async {
        guard activeInstall?.admissionID == admissionID else { return }
        activeInstall = nil
        switch result {
        case .success:
            installationStatus = .idle
            await refreshInstalled()
            await synchronizeScheduler()
        case .failure(let error) where error is CancellationError:
            installationStatus = .cancelled(modelID: modelID)
        case .failure(let error):
            installationStatus = .failed(modelID: modelID, message: Self.installMessage(for: error))
        }
    }

    private static func installMessage(for error: Error) -> String {
        guard let installError = error as? DesktopModelInstallError else { return "Die Modellinstallation konnte nicht abgeschlossen werden." }
        switch installError {
        case .insufficientSpace: return "Nicht genügend Speicherplatz für dieses Modell."
        case .downloadFailed: return "Der Modellabruf ist fehlgeschlagen. Prüfe die Netzwerkverbindung und versuche es erneut."
        case .hashMismatch, .byteCountMismatch, .invalidManifest, .activationFailed: return "Die Modellprüfung ist fehlgeschlagen. Bitte erneut herunterladen."
        case .notInstalled: return "Das Modell wurde nicht aktiviert. Bitte erneut versuchen."
        }
    }

    private func synchronizeScheduler() async {
        guard !invalidated else { return }
        await scheduler.update(settings: settings, installed: installed, residentCosts: residentCosts, memoryBudgetBytes: memoryBudgetBytes)
    }

    private func persistAndSynchronize() async {
        await settingsStore.save(settings)
        await synchronizeScheduler()
    }

    private func model(for id: String) -> DesktopModel? {
        DesktopModelCatalog.referenceModels.first { $0.id == id }
    }

    private func requireCompatibleModel(_ id: String) throws -> DesktopModel {
        guard let model = model(for: id), manifests[id] != nil else { throw DesktopModelProductError.unknownModel }
        guard osSupports(model.minimumMacOS) else { throw DesktopModelProductError.unsuitableOS }
        return model
    }

    private func requireInstalledModel(_ id: String) throws -> DesktopModel {
        let model = try requireCompatibleModel(id)
        guard installed.contains(id) else { throw DesktopModelProductError.notInstalled }
        return model
    }
}
