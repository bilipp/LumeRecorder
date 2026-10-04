// swift-tools-version: 6.0
// LumeRecorderKit — the shared wire contract (DTOs + coding) and a tiny async
// client for the LumeRecorder HTTP API. Foundation only: the Lume app consumes
// this as a local package, so it must never add a dependency to the app graph.

import PackageDescription

let package = Package(
    name: "LumeRecorderKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "LumeRecorderKit", targets: ["LumeRecorderKit"]),
    ],
    targets: [
        .target(
            name: "LumeRecorderKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LumeRecorderKitTests",
            dependencies: ["LumeRecorderKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
