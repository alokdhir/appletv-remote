// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleTVRemote",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AppleTVRemote",
            path: "Sources/AppleTVRemote",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
