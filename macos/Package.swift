// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Klangschrift",
    defaultLocalization: "de",
    // The pinned Moonshine binary is built for macOS 26; keep the package
    // deployment target aligned with the public SDK input and app metadata.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KlangschriftCore", targets: ["KlangschriftCore"]),
        .library(name: "KlangschriftHotkeys", targets: ["KlangschriftHotkeys"]),
        .library(name: "KlangschriftTextInsertion", targets: ["KlangschriftTextInsertion"]),
        .library(name: "KlangschriftPersistence", targets: ["KlangschriftPersistence"]),
        .library(name: "KlangschriftDesignSystem", targets: ["KlangschriftDesignSystem"]),
        .library(name: "KlangschriftPresentation", targets: ["KlangschriftPresentation"]),
        .library(name: "KlangschriftUI", targets: ["KlangschriftUI"]),
        .library(name: "KlangschriftDiagnostics", targets: ["KlangschriftDiagnostics"]),
        .library(name: "KlangschriftAudio", targets: ["KlangschriftAudio"]),
        .library(name: "KlangschriftTranscription", targets: ["KlangschriftTranscription"]),
        .library(name: "KlangschriftAppCore", targets: ["KlangschriftAppCore"]),
        .library(name: "KlangschriftAppIntegration", targets: ["KlangschriftAppIntegration"]),
        .library(name: "KlangschriftAppAdapters", targets: ["KlangschriftAppAdapters"]),
        .library(name: "KlangschriftAppComposition", targets: ["KlangschriftAppComposition"]),
        .library(name: "KlangschriftDesktopModelCatalog", targets: ["KlangschriftDesktopModelCatalog"]),
        .library(name: "KlangschriftDesktopModels", targets: ["KlangschriftDesktopModels"]),
        .library(name: "KlangschriftDesktopNativeModels", targets: ["KlangschriftDesktopNativeModels"]),
        .library(name: "KlangschriftDesktopModelProduct", targets: ["KlangschriftDesktopModelProduct"]),
        .executable(name: "KlangschriftDesktopModelInstaller", targets: ["KlangschriftDesktopModelInstaller"]),
        .executable(name: "KlangschriftDesktopNativeWorker", targets: ["KlangschriftDesktopNativeWorker"]),
        .executable(name: "KlangschriftApp", targets: ["KlangschriftApp"]),
    ],
    dependencies: [
        .package(path: "Vendor/DesktopSDKs/FluidAudio"),
        .package(path: "Vendor/DesktopSDKs/Moonshine"),
        .package(path: "Vendor/DesktopSDKs/WhisperKit"),
        .package(path: "Vendor/DesktopSDKs/Sherpa")
    ],
    targets: [
        .target(name: "KlangschriftCore"),
        .target(name: "KlangschriftHotkeys", dependencies: ["KlangschriftCore"]),
        .target(name: "KlangschriftTextInsertion", dependencies: ["KlangschriftCore"]),
        .target(name: "KlangschriftSQLiteShim", publicHeadersPath: "include"),
        .target(name: "KlangschriftPersistence", dependencies: ["KlangschriftCore", "KlangschriftSQLiteShim"]),
        .target(name: "KlangschriftDesignSystem"),
        .target(name: "KlangschriftPresentation", dependencies: ["KlangschriftDesignSystem"], resources: [.process("Resources")]),
        .target(
            name: "KlangschriftUI",
            dependencies: ["KlangschriftDesignSystem", "KlangschriftPresentation", "KlangschriftCore"],
            resources: [.process("Resources")]
        ),
        .target(name: "KlangschriftDiagnostics"),
        .target(name: "KlangschriftAudio", dependencies: ["KlangschriftCore"]),
        .target(name: "KlangschriftTranscription", dependencies: ["KlangschriftCore"]),
        .target(name: "KlangschriftAppCore", dependencies: ["KlangschriftCore", "KlangschriftHotkeys", "KlangschriftAudio", "KlangschriftPersistence", "KlangschriftTextInsertion", "KlangschriftTranscription"]),
        .target(name: "KlangschriftAppIntegration", dependencies: ["KlangschriftAppCore", "KlangschriftPersistence", "KlangschriftTranscription"]),
        .target(name: "KlangschriftAppAdapters", dependencies: ["KlangschriftAppCore", "KlangschriftHotkeys", "KlangschriftAudio", "KlangschriftPersistence", "KlangschriftTextInsertion", "KlangschriftPresentation", "KlangschriftUI"]),
        .target(name: "KlangschriftDesktopModelCatalog"),
        .target(name: "KlangschriftDesktopModels", dependencies: ["KlangschriftDesktopModelCatalog", "KlangschriftCore"]),
        .target(name: "KlangschriftDesktopNativeModels", dependencies: [
            "KlangschriftCore",
            "KlangschriftDesktopModels",
            "KlangschriftDesktopModelCatalog",
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "MoonshineVoice", package: "Moonshine"),
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "SherpaOnnxC", package: "Sherpa")
        ]),
        .target(name: "KlangschriftDesktopModelProduct", dependencies: ["KlangschriftDesktopModels", "KlangschriftDesktopModelCatalog", "KlangschriftDesktopNativeModels", "KlangschriftUI"]),
        .executableTarget(name: "KlangschriftDesktopModelInstaller", dependencies: ["KlangschriftDesktopModels"]),
        .executableTarget(name: "KlangschriftDesktopNativeWorker", dependencies: ["KlangschriftDesktopNativeModels"]),
        .target(name: "KlangschriftAppComposition", dependencies: ["KlangschriftAppIntegration", "KlangschriftAppAdapters", "KlangschriftAppCore", "KlangschriftPersistence", "KlangschriftPresentation", "KlangschriftUI", "KlangschriftDiagnostics", "KlangschriftAudio", "KlangschriftHotkeys", "KlangschriftTextInsertion", "KlangschriftCore", "KlangschriftDesktopModelProduct"]),
        .executableTarget(name: "KlangschriftApp", dependencies: ["KlangschriftUI", "KlangschriftPresentation", "KlangschriftAppComposition", "KlangschriftAppAdapters"]),
    ]
)
