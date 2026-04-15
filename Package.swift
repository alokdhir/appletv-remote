// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleTVRemote",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0")
    ],
    targets: [
        .target(
            name: "AppleTVProtocol",
            dependencies: [
                .product(name: "BigInt", package: "BigInt")
            ],
            path: "Sources/AppleTVProtocol"
        ),
        .executableTarget(
            name: "AppleTVRemote",
            dependencies: [
                "AppleTVProtocol"
            ],
            path: "Sources/AppleTVRemote",
            exclude: ["Resources/Info.plist"],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        )
    ]
)
