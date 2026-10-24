// swift-tools-version: 6.0
import PackageDescription

// AP04 desktop port: SDK library only. No CLI or test target is a product route.
let package = Package(
    name: "KlangschriftDesktopFluidAudio",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FluidAudio", targets: ["FluidAudio"])],
    targets: [
        .target(name: "FluidAudio", dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper"], path: "Sources/FluidAudio", exclude: ["ASR/Parakeet/Unified/benchmark.md"], resources: [.process("TTS/LuxTts/G2p/Resources")]),
        .target(name: "FastClusterWrapper", path: "Sources/FastClusterWrapper", publicHeadersPath: "include"),
        .target(name: "MachTaskSelfWrapper", path: "Sources/MachTaskSelfWrapper", publicHeadersPath: "include")
    ],
    cxxLanguageStandard: .cxx17
)
