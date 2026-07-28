// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMusicPlayer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacMusicPlayer", targets: ["MacMusicPlayer"]),
        .library(name: "MusicCore", targets: ["MusicCore"])
    ],
    targets: [
        .target(
            name: "MusicCore",
            path: "Sources/MusicCore"
        ),
        .executableTarget(
            name: "MacMusicPlayer",
            dependencies: ["MusicCore"],
            path: "Sources/MacMusicPlayer"
        ),
        .testTarget(
            name: "MusicCoreTests",
            dependencies: ["MusicCore"],
            path: "Tests/MusicCoreTests"
        )
    ]
)
