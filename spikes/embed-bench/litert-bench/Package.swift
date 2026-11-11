// swift-tools-version: 6.2
// Phase 3: measure EmbeddingGemma 2 through Google's LiteRT-LM Swift package. Research only, never shipped.
// The package comes from the pinned local clone ../deps/litert-lm (tag v0.19.1, commit recorded in PINS.md); its macOS
// binary (CLiteRTLM_mac.xcframework.zip) is checked against the checksum in that package's manifest.
import PackageDescription

let package = Package(
    name: "litert-bench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../bench-support"),
        .package(path: "../deps/litert-lm"),
        .package(path: "../provider-kit"),
    ],
    targets: [
        .executableTarget(
            name: "litert-dump",
            dependencies: [
                .product(name: "BenchSupport", package: "bench-support"),
                .product(name: "LiteRTLM", package: "litert-lm"),
            ],
            path: "Sources/litert-dump"
        ),
        .executableTarget(
            name: "litert-scale",
            dependencies: [
                .product(name: "BenchSupport", package: "bench-support"),
                .product(name: "LiteRTLM", package: "litert-lm"),
            ],
            path: "Sources/litert-scale"
        ),
        .executableTarget(
            name: "provider-bench",
            dependencies: [
                .product(name: "BenchSupport", package: "bench-support"),
                .product(name: "ProviderKit", package: "provider-kit"),
                .product(name: "LiteRTLM", package: "litert-lm"),

            ],
            path: "Sources/provider-bench"
        ),
    ]
)
