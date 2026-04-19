// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleTVRemote",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppleTVLogging",  targets: ["AppleTVLogging"]),
        .library(name: "AppleTVProtocol", targets: ["AppleTVProtocol"]),
        .library(name: "AppleTVIPC",      targets: ["AppleTVIPC"]),
        .executable(name: "atv",          targets: ["atv"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0")
    ],
    targets: [
        .target(
            name: "AppleTVLogging",
            path: "Sources/AppleTVLogging"
        ),
        .target(
            name: "AppleTVProtocol",
            dependencies: [
                "AppleTVLogging",
                .product(name: "BigInt", package: "BigInt")
            ],
            path: "Sources/AppleTVProtocol"
        ),
        .target(
            name: "AppleTVIPC",
            path: "Sources/AppleTVIPC"
        ),
        .executableTarget(
            name: "AppleTVRemote",
            dependencies: [
                "AppleTVLogging",
                "AppleTVProtocol",
                "AppleTVIPC"
            ],
            path: "Sources/AppleTVRemote",
            exclude: ["Resources/Info.plist"],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        ),
        .executableTarget(
            name: "atv",
            dependencies: [
                "AppleTVIPC",
                "AppleTVProtocol",
                "AppleTVLogging"
            ],
            path: "Sources/atv"
        ),
        .testTarget(
            name: "AppleTVProtocolTests",
            dependencies: ["AppleTVProtocol"],
            path: "Tests/AppleTVProtocolTests"
        )
    ]
)
