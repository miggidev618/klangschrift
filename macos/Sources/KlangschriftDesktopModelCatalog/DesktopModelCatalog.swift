import Foundation

/// AP03's source-scoped catalogue.  It is deliberately data only: AP04 owns
/// all runtime loading and AP09 owns Windows SDK/artifact acceptance.
public enum DesktopModelFamily: String, Sendable, CaseIterable {
    case fluidAudioCoreML
    case moonshineStreaming
    case whisperKitCoreML
    case sherpaZipformer
}

public enum DesktopRouteState: String, Sendable {
    case planned
    case blocked
    case pinRequired
}

public enum DesktopFileSet: String, Sendable {
    /// The source manifest contains each named file and its SHA-256.
    case phonon2CoreML
    case parakeetV3CoreML
    case parakeetReduxCoreML
    case moonshineStreamingORT
    case whisperCoreMLWithOfflineTokenizer
    case sherpaZipformerINT8
    case whisperCppGGML
    case parakeetV3ONNX
    case phonon2CPUArchive

    public var requiredPaths: [String] {
        switch self {
        case .moonshineStreamingORT:
            return ["adapter.ort", "cross_kv.ort", "decoder_kv.ort", "encoder.ort", "frontend.model.ort", "frontend.weights.ort", "streaming_config.json", "tokenizer.bin"]
        case .whisperCoreMLWithOfflineTokenizer:
            return ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc", "Tokenizer/config.json", "Tokenizer/tokenizer.json", "Tokenizer/vocab.json"]
        case .sherpaZipformerINT8:
            return ["encoder-epoch-99-avg-1.int8.onnx", "decoder-epoch-99-avg-1.int8.onnx", "joiner-epoch-99-avg-1.int8.onnx", "tokens.txt"]
        case .parakeetV3CoreML:
            return ["Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "Preprocessor.mlmodelc", "parakeet_v3_vocab.json", "parakeet_vocab.json"]
        case .parakeetReduxCoreML, .phonon2CoreML:
            return ["Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "Preprocessor.mlmodelc", "parakeet_vocab.json"]
        case .whisperCppGGML:
            return ["ggml-model.bin"]
        case .parakeetV3ONNX:
            return ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
        case .phonon2CPUArchive:
            return ["AP09 official archive manifest required"]
        }
    }
}

public struct DesktopArtifactPin: Sendable, Equatable {
    public let revision: String
    public let totalBytes: Int
    /// SHA-256 of the source manifest whose named files carry SHA-256 pins.
    public let manifestSHA256: String
    public let fileSet: DesktopFileSet
    public let source: String
}

public struct DesktopRuntimePin: Sendable, Equatable {
    public let name: String
    public let version: String
    /// Never use a model-artifact revision as a runtime SDK commit.
    public let revision: String
    public let revisionProvenance: String
    public let nativeBoundary: String
    public let offlineConstraint: String?
}

public struct DesktopLicense: Sendable, Equatable {
    public let identifier: String
    public let attribution: String
    /// Packaging/redistribution is intentionally not granted by this field.
    public let redistributionGate: String
}

public struct DesktopModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let family: DesktopModelFamily
    public let language: String
    public let title: String
    public let artifact: DesktopArtifactPin
    public let runtime: DesktopRuntimePin
    public let minimumMacOS: Int
    public let architectures: Set<String>
    public let state: DesktopRouteState
    public let license: DesktopLicense
    public let desktopPortRevision: String
}

public struct WindowsModelRoute: Sendable, Equatable, Identifiable {
    public let id: String
    public let sourceReferenceID: String?
    public let family: String
    public let language: String
    public let runtime: String
    public let state: DesktopRouteState
    /// Present only when the exact artifact is already source-pinned.  A nil
    /// value is a hard AP09 pin gate, never a download instruction.
    public let artifact: DesktopArtifactPin?
    public let architecture: String
    public let license: DesktopLicense
    public let gate: String
}

public enum DesktopModelCatalog {
    public static let desktopPortRevision = "desktop-model-catalog-ap03-20261006"

    public static let referenceModels: [DesktopModel] = [
        fluid("phonon2-coreml", "Phonon-2", "English", .phonon2CoreML, "a812a0dfef205660787ef6234317ab79acf4d5d6", 357_755_579, "a1c3c59a22c630555979cfedd228eed6d13db67ae52f24acc13c5c7f3f79c812", 15),
        fluid("phonon2-compact-coreml", "Phonon-2 Compact", "English", .phonon2CoreML, "a812a0dfef205660787ef6234317ab79acf4d5d6", 212_702_694, "43ba4116308b73331fdd186f68280adbba49adcfa6186d20383a8ac0a64cc7ff", 15),
        fluid("parakeet-v3-coreml", "Parakeet v3", "Mehrsprachig", .parakeetV3CoreML, "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe", 483_263_046, "9d6b259893cc564f57612702573aa8f87bb3a841857fda091d9adcb01f1830cc", 14),
        fluid("parakeet-redux-coreml", "Parakeet Redux", "Mehrsprachig", .parakeetReduxCoreML, "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9", 220_310_684, "f69aa22e43476bed6a1ca92a8138b8200fa69d58f699c1a65361c552a1e908b6", 15),
        moonshine("moonshine-tiny-streaming-de", "Moonshine Tiny DE", "Deutsch", 32_317_004, "5dbf5f7c15030309b1f09ca00b52252f3a8dec71337952fa98f1cad472ba9fb2"),
        moonshine("moonshine-tiny-streaming-en", "Moonshine Tiny EN", "English", 45_233_659, "e5c7002d25908575f4f761545fd3e14e60ad7c21aa1a6714db5eafe042c68f02"),
        moonshine("moonshine-tiny-streaming-ar", "Moonshine Tiny AR", "Arabisch", 32_349_411, "c39c9bd278a60a9dcbc6ac7d8ebacdfdd581cf16152be4924dcdd72431745444"),
        moonshine("moonshine-tiny-streaming-es", "Moonshine Tiny ES", "Spanisch", 32_316_573, "ae131ba2a23bd5d70a8f83971a559167f6b8bf3931c80c049c72f02c4447ffd9"),
        moonshine("moonshine-tiny-streaming-ja", "Moonshine Tiny JA", "Japanisch", 32_319_961, "83d252411703c0de96692f81a64678b82e4a9328b9c1f750fe861a48ef4997c2"),
        moonshine("moonshine-tiny-streaming-tl", "Moonshine Tiny TL", "Tagalog", 32_309_481, "4189db162d27859f1272ae1e5fdbccfd250987e5498d0c95a731c3ef49db8275"),
        moonshine("moonshine-tiny-streaming-vi", "Moonshine Tiny VI", "Vietnamesisch", 32_309_008, "b78e962a7a9d2332335182ea9ad15caa3e2ed2581320b4fdfb40b76e75ec564a"),
        moonshine("moonshine-tiny-streaming-zh", "Moonshine Tiny ZH", "Mandarin", 32_290_152, "e0c2a1b1297c614922d08e0a34825560ee54db62f093489a834bf5ea0c6c9af7"),
        moonshine("moonshine-small-streaming-de", "Moonshine Small DE", "Deutsch", 121_800_823, "92ad905f99bdeaeed24242eb2db4a817a3e696ee9a46feeb0de8dd7c95acbfa0"),
        moonshine("moonshine-small-streaming-en", "Moonshine Small EN", "English", 142_300_974, "73730d0f28a97db6726b4e597d10087758fac4cf8b36867f6554be8c06509657"),
        moonshine("moonshine-small-streaming-es", "Moonshine Small ES", "Spanisch", 121_800_392, "e0c71283064331ff931c9120ad0c3ec829b06f01b79bb7e737c5de0f0cb58568"),
        moonshine("moonshine-small-streaming-ja", "Moonshine Small JA", "Japanisch", 121_803_780, "f6e06d512207be271f72f2fbe9b042a6e134e33ebb1b3b0330c0f11105823b85"),
        moonshine("moonshine-medium-streaming-en", "Moonshine Medium EN", "English", 269_141_623, "53199b0c37e205fa65f675ed2043b72f938e7a70dccc60b27f56dffef917c36c"),
        whisper("whisper-tiny-coreml", "Whisper Tiny", "Mehrsprachig", 80_766_746, "800d1864c9c7e90575ed30f17a3b2e80eccd925ee31a124c02920c066be57948", "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"),
        whisper("whisper-tiny-en-coreml", "Whisper Tiny EN", "English", 80_322_470, "a8a138f3c3809d6c5e74edf0e476444ddd961d5a12c284cadae25020d295d579", "87c7102498dcde7456f24cfd30239ca606ed9063"),
        whisper("whisper-base-coreml", "Whisper Base", "Mehrsprachig", 150_850_802, "66fa4f7b12cb554d81fea695856dd10a73c9520e728b660dbbcdc33f03b5fe36", "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"),
        whisper("whisper-base-en-coreml", "Whisper Base EN", "English", 150_407_060, "56c60e49da01ee4f30911bed3b0e08f9cd0438ad56347ae4f7d58f265749c141", "87c7102498dcde7456f24cfd30239ca606ed9063"),
        sherpa()
    ]

    public static let windowsRoutes: [WindowsModelRoute] =
        referenceModels.filter { $0.family == .moonshineStreaming }.map { model in
            WindowsModelRoute(
                id: "windows-\(model.id)", sourceReferenceID: model.id, family: "Moonshine Streaming", language: model.language,
                runtime: "Moonshine native Windows C/C++ ABI", state: .planned, artifact: model.artifact, architecture: "win-x64 CPU",
                license: moonshineLicense, gate: "AP09: pin matching Windows native library, ABI and ONNX Runtime compatibility before reusing this artifact.")
        } + [
            unresolvedWindows("windows-whisper-tiny-ggml", "Whisper.cpp Tiny", "Mehrsprachig", .whisperCppGGML),
            unresolvedWindows("windows-whisper-tiny-en-ggml", "Whisper.cpp Tiny EN", "English", .whisperCppGGML),
            unresolvedWindows("windows-whisper-base-ggml", "Whisper.cpp Base", "Mehrsprachig", .whisperCppGGML),
            unresolvedWindows("windows-whisper-base-en-ggml", "Whisper.cpp Base EN", "English", .whisperCppGGML),
            unresolvedWindows("windows-sherpa-zipformer-en-int8", "Sherpa Zipformer EN", "English", .sherpaZipformerINT8),
            unresolvedWindows("windows-parakeet-v3-onnx-int8", "Sherpa Parakeet v3 ONNX", "Mehrsprachig", .parakeetV3ONNX),
            unresolvedWindows("windows-phonon2-cpu", "Phonon-2 CPU feasibility", "English", .phonon2CPUArchive)
        ]

    public static let localRuntimePins: [DesktopRuntimePin] = [fluidRuntime, moonshineRuntime, whisperRuntime, sherpaRuntime]

    private static func fluid(_ id: String, _ title: String, _ language: String, _ set: DesktopFileSet, _ revision: String, _ bytes: Int, _ sha: String, _ minOS: Int) -> DesktopModel {
        DesktopModel(id: id, family: .fluidAudioCoreML, language: language, title: title,
            artifact: .init(revision: revision, totalBytes: bytes, manifestSHA256: sha, fileSet: set, source: "iOS source-scoped fixed manifest; FluidInference Core ML port"),
            runtime: fluidRuntime, minimumMacOS: minOS, architectures: ["arm64"], state: .planned, license: fluidLicense, desktopPortRevision: desktopPortRevision)
    }

    private static func moonshine(_ id: String, _ title: String, _ language: String, _ bytes: Int, _ sha: String) -> DesktopModel {
        DesktopModel(id: id, family: .moonshineStreaming, language: language, title: title,
            artifact: .init(revision: "234f60faa0eb388b01cdf7e60aca232af37aefda", totalBytes: bytes, manifestSHA256: sha, fileSet: .moonshineStreamingORT, source: "iOS source-scoped fixed manifest; download.moonshine.ai"),
            runtime: moonshineRuntime, minimumMacOS: 14, architectures: ["arm64"], state: .planned, license: moonshineLicense, desktopPortRevision: desktopPortRevision)
    }

    private static func whisper(_ id: String, _ title: String, _ language: String, _ bytes: Int, _ sha: String, _ tokenizerRevision: String) -> DesktopModel {
        DesktopModel(id: id, family: .whisperKitCoreML, language: language, title: title,
            artifact: .init(revision: "0f63a7800b00dd0226abd051b906c246e1907482-\(tokenizerRevision)", totalBytes: bytes, manifestSHA256: sha, fileSet: .whisperCoreMLWithOfflineTokenizer, source: "iOS source-scoped fixed manifest; argmaxinc/whisperkit-coreml and OpenAI tokenizer"),
            runtime: whisperRuntime, minimumMacOS: 14, architectures: ["arm64"], state: .planned, license: whisperLicense, desktopPortRevision: desktopPortRevision)
    }

    private static func sherpa() -> DesktopModel {
        DesktopModel(id: "sherpa-zipformer-en-int8", family: .sherpaZipformer, language: "English", title: "Zipformer EN",
            artifact: .init(revision: "d42f2d9f7ca24806fb667456a18a9f1b60f70d16", totalBytes: 43_649_301, manifestSHA256: "cd6951e8686c340b3cd9f2494d336674f48b75e5e2eb46d14daa4b5b428cc3a3", fileSet: .sherpaZipformerINT8, source: "iOS source-scoped fixed manifest; csukuangfj/sherpa-onnx streaming Zipformer"),
            runtime: sherpaRuntime, minimumMacOS: 14, architectures: ["arm64"], state: .planned, license: sherpaLicense, desktopPortRevision: desktopPortRevision)
    }

    private static func unresolvedWindows(_ id: String, _ family: String, _ language: String, _ fileSet: DesktopFileSet) -> WindowsModelRoute {
        WindowsModelRoute(id: id, sourceReferenceID: nil, family: family, language: language, runtime: windowsRuntime(for: fileSet), state: .pinRequired, artifact: nil, architecture: "win-x64 CPU", license: license(for: fileSet), gate: "AP09 must obtain the official release/archive into its bounded staging path, record exact revision, bytes, file set and SHA-256, then verify native ABI. No route is installable before that.")
    }

    private static func windowsRuntime(for set: DesktopFileSet) -> String {
        switch set {
        case .whisperCppGGML: return "whisper.cpp native Windows DLL"
        case .sherpaZipformerINT8, .parakeetV3ONNX: return "Sherpa-ONNX Windows C API / ONNX Runtime"
        case .phonon2CPUArchive: return "Fermion Research app-local Python CPU worker"
        default: return "not a Windows route"
        }
    }

    private static func license(for set: DesktopFileSet) -> DesktopLicense {
        switch set {
        case .whisperCppGGML: return whisperLicense
        case .sherpaZipformerINT8, .parakeetV3ONNX: return sherpaLicense
        case .phonon2CPUArchive: return fluidLicense
        default: return DesktopLicense(identifier: "unresolved", attribution: "AP09 source required", redistributionGate: "unverified")
        }
    }

    private static let fluidRuntime = DesktopRuntimePin(name: "FluidAudio", version: "0.17.5", revision: "0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7", revisionProvenance: "read-only local vendor Git HEAD; vendor worktree is not clean", nativeBoundary: "Core ML / FluidAudio; AP04 must validate SDK call surface", offlineConstraint: "iOS reference sets ModelHub.offlineMode = true; no desktop port is implemented yet.")
    private static let moonshineRuntime = DesktopRuntimePin(name: "Moonshine Voice", version: "0.1.5", revision: "unresolved-sdk-revision", revisionProvenance: "the iOS model revision 234f60faa0eb388b01cdf7e60aca232af37aefda is not an SDK commit; AP04 must bind an official SDK/archive pin", nativeBoundary: "Moonshine C API, macOS universal XCFramework slice observed", offlineConstraint: "Fixed local .ort set; AP04 must validate the native library against it.")
    private static let whisperRuntime = DesktopRuntimePin(name: "WhisperKit", version: "1.1.0", revision: "1e2a163736dfa5a198e637ae44c114e1c6d5cc2d", revisionProvenance: "read-only local vendor Git HEAD; local tokenizer patch separately hashed", nativeBoundary: "Swift SDK/Core ML", offlineConstraint: "iOS tokenizer patch SHA-256 1fd32f3f1acb06883445553d2393281501c437de29bdbb6d2eac4882af23a0a7; AP04 must port or replace it deliberately.")
    private static let sherpaRuntime = DesktopRuntimePin(name: "Sherpa-ONNX", version: "1.13.8", revision: "archive-sha256:82d5cb3af38c3cb4871c3532a6c7dc86d6b7db1077bcc9d6a1047100976f199b", revisionProvenance: "read-only Vendor/Sherpa/SOURCE.json macOS v1.13.8 archive; d42f2d9f7ca24806fb667456a18a9f1b60f70d16 remains the Zipformer model revision", nativeBoundary: "Sherpa C API; macOS universal XCFramework slice observed", offlineConstraint: "Recognizer must receive only fixed local ONNX/token files.")

    private static let fluidLicense = DesktopLicense(identifier: "Apache-2.0 / CC-BY-4.0 weights", attribution: "FluidInference FluidAudio 0.17.5; Fermion Research Phonon-2; NVIDIA/FluidInference Parakeet", redistributionGate: "AP07 must ship complete applicable texts and verify redistribution scope; this catalog grants nothing.")
    private static let moonshineLicense = DesktopLicense(identifier: "MIT", attribution: "Moonshine AI / Useful Sensors, Moonshine Voice 0.1.5 and 13 streaming models", redistributionGate: "AP07 must include native third-party notices and confirm the selected archive's terms.")
    private static let whisperLicense = DesktopLicense(identifier: "MIT", attribution: "Argmax WhisperKit 1.1.0; OpenAI Whisper Tiny/Base", redistributionGate: "AP07 must include both complete texts and review the chosen artifact terms.")
    private static let sherpaLicense = DesktopLicense(identifier: "Apache-2.0 / MIT dependency", attribution: "k2-fsa / csukuangfj Sherpa-ONNX Zipformer; ONNX Runtime", redistributionGate: "AP07 must include complete Sherpa, ONNX Runtime and Kaldi Native Fbank notices after artifact audit.")
}
