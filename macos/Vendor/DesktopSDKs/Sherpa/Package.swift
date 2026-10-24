// swift-tools-version: 6.1
import PackageDescription
// Every platform slice is a framework; macOS is reproducibly wrapped from the fixed upstream dylib.
let package = Package(name: "KlangschriftSherpa", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "SherpaOnnxC", targets: ["SherpaOnnxC"])], targets: [.binaryTarget(name: "SherpaOnnxC", path: "SherpaOnnxC.xcframework")])
