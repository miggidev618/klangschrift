// swift-tools-version: 5.10
import PackageDescription

// AP04 desktop port: local Core ML only; no CLI, server, TTS, speaker, or
// package dependency. Resolving this package cannot fetch a tokenizer or SDK.
let package = Package(
    name: "KlangschriftDesktopWhisperKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WhisperKit", targets: ["WhisperKit"])],
    targets: [
        .target(name: "ArgmaxCore", swiftSettings: swiftSettings()),
        .target(name: "WhisperKit", dependencies: ["ArgmaxCore"], swiftSettings: swiftSettings())
    ],
    swiftLanguageVersions: [.v5]
)

func swiftSettings() -> [SwiftSetting] { [.enableExperimentalFeature("StrictConcurrency")] }
