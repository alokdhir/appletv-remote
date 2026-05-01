// swift-tools-version: 6.0
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
            path: "Sources/AppleTVLogging",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AppleTVProtocol",
            dependencies: [
                "AppleTVLogging",
                .product(name: "BigInt", package: "BigInt")
            ],
            path: "Sources/AppleTVProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AppleTVIPC",
            path: "Sources/AppleTVIPC",
            swiftSettings: [.swiftLanguageMode(.v6)]
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
                .process("Resources/Assets.xcassets"),
                .copy("Resources/AppIcons")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "atv",
            dependencies: [
                "AppleTVIPC",
                "AppleTVProtocol",
                "AppleTVLogging"
            ],
            path: "Sources/atv",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppleTVProtocolTests",
            dependencies: ["AppleTVProtocol"],
            path: "Tests/AppleTVProtocolTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppleTVIPCTests",
            dependencies: ["AppleTVIPC"],
            path: "Tests/AppleTVIPCTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
