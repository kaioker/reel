// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Reel", path: "Sources/Reel")
    ]
)
