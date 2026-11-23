// swift-tools-version:5.9
import PackageDescription
import Foundation

// FFmpeg's decoding libraries (in-app decoder) — built by scripts/build-ffmpeg-libs.sh into .deps/.
// At runtime they're found in Reel.app/Contents/Frameworks (or in .deps/ when running a dev build).
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ffmpeg = root + "/.deps/ffmpeg-shared"

let package = Package(
    name: "Reel",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CFFmpeg", path: "Sources/CFFmpeg"),
        .executableTarget(
            name: "Reel",
            dependencies: ["CFFmpeg"],
            path: "Sources/Reel",
            swiftSettings: [.unsafeFlags(["-Xcc", "-I" + ffmpeg + "/include"])],
            linkerSettings: [.unsafeFlags([
                "-L" + ffmpeg + "/lib",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", ffmpeg + "/lib",
            ])]
        ),
    ]
)
