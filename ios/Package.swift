// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KlangschriftCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KlangschriftCore", targets: ["KlangschriftCore"])
    ],
    dependencies: [.package(path: "Vendor/mlx-swift"), .package(path: "Vendor/mlx-audio-swift"), .package(path: "Vendor/FluidAudio"), .package(path: "Vendor/Moonshine"), .package(path: "Vendor/WhisperKit"), .package(path: "Vendor/Sherpa")],
    targets: [
        .target(name: "KlangschriftCore", dependencies: [
            .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "MoonshineVoice", package: "Moonshine"),
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "SherpaOnnxC", package: "Sherpa")
        ], path: "Core")
    ]
)
