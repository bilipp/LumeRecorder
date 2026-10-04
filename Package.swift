// swift-tools-version: 6.0
// LumeRecorder — self-hosted DVR server for the Lume IPTV app.

import PackageDescription

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "LumeRecorder",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "lume-recorder", targets: ["lume-recorder"]),
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
    ],
    dependencies: [
        .package(path: "Kit"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "6.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "RecorderCore",
            dependencies: [
                .product(name: "LumeRecorderKit", package: "Kit"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "lume-recorder",
            dependencies: [
                "RecorderCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "RecorderCoreTests",
            dependencies: [
                "RecorderCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
