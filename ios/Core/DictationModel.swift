import CryptoKit
import Foundation

public enum DictationModelID: String, CaseIterable, Codable, Sendable, Identifiable {
    case phonon2CoreML = "phonon2-coreml"
    case parakeetV3CoreML = "parakeet-v3-coreml"
    case moonshineTinyStreamingDE = "moonshine-tiny-streaming-de"
    case moonshineTinyStreamingEN = "moonshine-tiny-streaming-en"

    case moonshineMediumStreamingEN = "moonshine-medium-streaming-en"
    case moonshineSmallStreamingDE = "moonshine-small-streaming-de"
    case moonshineSmallStreamingEN = "moonshine-small-streaming-en"
    case moonshineSmallStreamingES = "moonshine-small-streaming-es"
    case moonshineSmallStreamingJA = "moonshine-small-streaming-ja"
    case moonshineTinyStreamingAR = "moonshine-tiny-streaming-ar"
    case moonshineTinyStreamingES = "moonshine-tiny-streaming-es"
    case moonshineTinyStreamingJA = "moonshine-tiny-streaming-ja"
    case moonshineTinyStreamingTL = "moonshine-tiny-streaming-tl"
    case moonshineTinyStreamingVI = "moonshine-tiny-streaming-vi"
    case moonshineTinyStreamingZH = "moonshine-tiny-streaming-zh"
    case parakeetReduxCoreML = "parakeet-redux-coreml"
    case phonon2CompactCoreML = "phonon2-compact-coreml"

    case whisperTinyCoreML = "whisper-tiny-coreml"
    case whisperTinyENCoreML = "whisper-tiny-en-coreml"
    case whisperBaseCoreML = "whisper-base-coreml"
    case whisperBaseENCoreML = "whisper-base-en-coreml"

    case sherpaZipformerEN = "sherpa-zipformer-en-int8"

    public var id: String { rawValue }
}

public struct DictationModelDescriptor: Sendable, Equatable {
    public let id: DictationModelID
    public let title: String
    public let subtitle: String
    public let language: String
    public let runtime: String
    public let bundleDirectory: String
    public let revision: String
    public let bundleBytes: Int
    public let manifestSHA256: String
    public let performanceSummary: String

    public static func descriptor(for id: DictationModelID) -> Self {
        switch id {
        case .phonon2CoreML:
            return Self(
                id: id,
                title: "Phonon-2",
                subtitle: "Fermion Research · kompakt für Englisch",
                language: "English",
                runtime: "Core ML · CPU + Neural Engine",
                bundleDirectory: "Phonon2CoreML",
                revision: "a812a0dfef205660787ef6234317ab79acf4d5d6",
                bundleBytes: 357_755_579,
                manifestSHA256: "a1c3c59a22c630555979cfedd228eed6d13db67ae52f24acc13c5c7f3f79c812",
                performanceSummary: "Noch nicht gemessen"
            )
        case .parakeetV3CoreML:
            return Self(
                id: id,
                title: "Parakeet v3",
                subtitle: "Mehrsprachiges lokales Modell",
                language: "Mehrsprachig",
                runtime: "Core ML · CPU + Neural Engine",
                bundleDirectory: "ParakeetV3CoreML",
                revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
                bundleBytes: 483_263_046,
                manifestSHA256: "9d6b259893cc564f57612702573aa8f87bb3a841857fda091d9adcb01f1830cc",
                performanceSummary: "Noch nicht gemessen"
            )
        case .moonshineTinyStreamingDE:
            return Self(id: id, title: "Moonshine Tiny DE", subtitle: "Kompaktes lokales Deutsch-Modell", language: "Deutsch", runtime: "Moonshine · CPU", bundleDirectory: "MoonshineTinyStreamingDE", revision: "234f60faa0eb388b01cdf7e60aca232af37aefda", bundleBytes: 32_317_004, manifestSHA256: "5dbf5f7c15030309b1f09ca00b52252f3a8dec71337952fa98f1cad472ba9fb2", performanceSummary: "Noch nicht gemessen")
        case .moonshineTinyStreamingEN:
            return Self(id: id, title: "Moonshine Tiny EN", subtitle: "Kompaktes lokales Englisch-Modell", language: "English", runtime: "Moonshine · CPU", bundleDirectory: "MoonshineTinyStreamingEN", revision: "234f60faa0eb388b01cdf7e60aca232af37aefda", bundleBytes: 45_233_659, manifestSHA256: "e5c7002d25908575f4f761545fd3e14e60ad7c21aa1a6714db5eafe042c68f02", performanceSummary: "Noch nicht gemessen")
        case .whisperTinyCoreML, .whisperTinyENCoreML, .whisperBaseCoreML, .whisperBaseENCoreML: return DictationWhisperModels.descriptor(id)
        case .sherpaZipformerEN: return DictationSherpaModel.descriptor
        default: return DictationExpandedModels.descriptor(id)
        }
    }

    /// The public source export deliberately ships no model artifacts.
    public var isBundled: Bool { false }

    /// Matches the languages offered by Settings, including only supported
    /// multilingual families rather than treating every model as every language.
    public func matchesLanguageFilter(_ selected: String) -> Bool {
        let selected = selected == "Englisch" ? "English" : selected
        if selected == "Alle Modelle" || selected == "Alle Sprachen" || selected == language { return true }
        switch id {
        case .parakeetV3CoreML, .parakeetReduxCoreML:
            return ["English", "Deutsch", "Spanisch"].contains(selected)
        case .whisperTinyCoreML, .whisperBaseCoreML:
            return ["English", "Deutsch", "Spanisch", "Arabisch", "Japanisch", "Mandarin", "Tagalog", "Vietnamesisch"].contains(selected)
        default: return false
        }
    }
}

public enum DictationModelSelection {
    public static let defaultsKey = "klangschrift.dictation-model.v1"
    public static let offeredModels: [DictationModelID] = [.whisperBaseCoreML, .whisperBaseENCoreML, .whisperTinyCoreML, .moonshineSmallStreamingDE, .moonshineSmallStreamingEN, .parakeetReduxCoreML]
    public static let defaultModel: DictationModelID = .whisperBaseCoreML

    /// Models are supplied through the explicit installer after a public self-build.
    public static func visibleModels(whisperBaseInstalled: Bool) -> [DictationModelID] {
        offeredModels
    }

    /// Read-only effective selection. Never replace a saved choice during lookup.
    public static func selected(defaults: UserDefaults = .standard,
                                isInstalled: (DictationModelID) -> Bool = DictationModelStorage.isInstalled) -> DictationModelID {
        let baseReady = isInstalled(defaultModel)
        if let raw = defaults.string(forKey: defaultsKey), let saved = DictationModelID(rawValue: raw),
           offeredModels.contains(saved), isInstalled(saved) { return saved }
        if baseReady { return defaultModel }
        return offeredModels.first(where: isInstalled) ?? defaultModel
    }

    /// Explicit host migration, only after the replacement has been verified installed.
    public static func migrateIfReady(defaults: UserDefaults = .standard,
                                      whisperBaseInstalled: Bool) {
        guard whisperBaseInstalled, let raw = defaults.string(forKey: defaultsKey),
              !offeredModels.contains(where: { $0.rawValue == raw }) else { return }
        defaults.set(defaultModel.rawValue, forKey: defaultsKey)
    }

    public static func select(_ model: DictationModelID, defaults: UserDefaults = .standard) {
        guard offeredModels.contains(model) else { return }
        defaults.set(model.rawValue, forKey: defaultsKey)
    }
}

/// Immutable selection captured before a recorder or keyboard job starts.
/// A Settings write never changes this value after construction.
public struct DictationJob: Sendable, Equatable {
    public let modelID: DictationModelID
    public init(modelID: DictationModelID) { self.modelID = modelID }
}

public enum DictationModelManifest {
    private struct Manifest: Decodable {
        let modelID: String
        let revision: String
        let files: [String: String]
        let totalBytes: Int

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id", revision, files, totalBytes = "total_bytes"
        }
    }

    /// Validates only files bundled by the selected model. It never resolves another model
    /// and never attempts a network repair when an asset is absent or changed.
    public static func validate(_ model: DictationModelID, directory: URL) throws {
        let descriptor = DictationModelDescriptor.descriptor(for: model)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              SHA256.hash(data: manifestData).map({ String(format: "%02x", $0) }).joined() == descriptor.manifestSHA256,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.modelID == model.rawValue,
              manifest.revision == descriptor.revision,
              manifest.totalBytes == descriptor.bundleBytes,
              !manifest.files.isEmpty else {
            throw LocalTranscriberError.modelMissing
        }

        var bytes = 0
        for (relativePath, expectedHash) in manifest.files {
            guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else { throw LocalTranscriberError.modelMissing }
            let file = directory.appendingPathComponent(relativePath)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, try sha256(file) == expectedHash else {
                throw LocalTranscriberError.modelMissing
            }
            bytes += size
        }
        guard bytes == manifest.totalBytes else { throw LocalTranscriberError.modelMissing }
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum DictationModelStorage {
    public static func directory(for model: DictationModelID) -> URL {
        let descriptor = DictationModelDescriptor.descriptor(for: model)
        if descriptor.isBundled { return Bundle.main.resourceURL!.appendingPathComponent(descriptor.bundleDirectory, isDirectory: true) }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klangschrift/Models", isDirectory: true)
        return root.appendingPathComponent("\(model.rawValue)-\(descriptor.revision)", isDirectory: true)
    }

    public static func isInstalled(_ model: DictationModelID) -> Bool {
        (try? DictationModelManifest.validate(model, directory: directory(for: model))) != nil
    }
}
