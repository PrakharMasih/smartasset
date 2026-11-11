// swift-tools-version: 6.2
// Phase 3: measure Whisper through WhisperKit (Argmax, MIT). Research only, never shipped.
// The package comes from the pinned local clone ../deps/argmax-oss-swift (tag v1.1.1, commit in PINS.md). Its server
// dependencies (Vapor, OpenAPI) are behind BUILD_ALL, which is left unset, so only swift-argument-parser is resolved.
import PackageDescription

let package = Package(
    name: "whisperkit-bench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../bench-support"),
        .package(path: "../deps/argmax-oss-swift"),
        // WhisperKit's manifest lists swift-argument-parser by URL (only its CLI uses it). The pinned local clone replaces the URL, so
        // resolving needs no network.
        .package(path: "../deps/swift-argument-parser"),
    ],
    targets: [
        .executableTarget(
            name: "whisperkit-run",
            dependencies: [
                .product(name: "BenchSupport", package: "bench-support"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/whisperkit-run"
        )
    ]
)
