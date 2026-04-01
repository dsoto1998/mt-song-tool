// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MTSongTool",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MTSongTool",
            path: "Sources/MTSongTool",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
