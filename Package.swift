// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StreamCapture",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "StreamCapture", path: "Sources/StreamCapture")
    ]
)
