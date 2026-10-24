// swift-tools-version: 6.1
import PackageDescription

// AP04 desktop port: fixed local binary plus file-transcription wrapper only.
let package = Package(
    name: "KlangschriftDesktopMoonshine",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MoonshineVoice", type: .static, targets: ["MoonshineVoice"])],
    targets: [
        .binaryTarget(name: "Moonshine", path: "Moonshine.xcframework"),
        .target(name: "MoonshineVoice", dependencies: ["Moonshine"], path: "Sources/MoonshineVoice", linkerSettings: [.linkedLibrary("c++")])
    ]
)
