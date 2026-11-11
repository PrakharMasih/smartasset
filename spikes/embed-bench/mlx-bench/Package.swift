// swift-tools-version: 6.2
// Phase 3: measure EmbeddingGemma 2 through the community MLX Swift runtime. Research only, never shipped.
// The runtime comes from the pinned local clone ../../eg2 (commit recorded in PINS.md); its dependency revisions are
// pinned by the Package.resolved copied next to this file.
import PackageDescription

let package = Package(
    name: "mlx-bench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../bench-support"),
        .package(path: "../../eg2"),
        // The runtime's manifest and its dependencies' manifests name these by URL. Each pinned local clone (revisions in PINS.md,
        // equal to the runtime's Package.resolved) takes the place of its URL, so resolving needs no network.
        .package(path: "../deps/mlx-swift"),
        .package(path: "../deps/swift-transformers"),
        .package(path: "../deps/swift-huggingface"),
        .package(path: "../deps/swift-jinja"),
        .package(path: "../deps/swift-collections"),
        .package(path: "../deps/swift-crypto"),
        .package(path: "../deps/swift-asn1"),
        .package(path: "../deps/swift-numerics"),
        .package(path: "../deps/eventsource"),
        .package(path: "../deps/yyjson"),
        .package(path: "../provider-kit"),
    ],
    targets: [
        .executableTarget(
            name: "mlx-dump",
            dependencies: [
                .product(name: "BenchSupport", package: "bench-support"),
                .product(name: "EmbeddingGemma2", package: "eg2"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/mlx-dump"
        ),
        .executableTarget(
            name: "mlx-scale",
            dependencies: [
                .product(name: "BenchSupport", package: "bench-support"),
                .product(name: "EmbeddingGemma2", package: "eg2"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/mlx-scale"
        ),
        .executableTarget(
            name: "mlx-queries",
            dependencies: [
                .product(name: "BenchSupport", package: "bench-support"),
                .product(name: "EmbeddingGemma2", package: "eg2"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/mlx-queries"
        ),
        .executableTarget(
            name: "provider-bench",
            dependencies: [
                .product(name: "BenchSupport", package: "bench-support"),
                .product(name: "ProviderKit", package: "provider-kit"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "EmbeddingGemma2", package: "eg2"),
            ],
            path: "Sources/provider-bench"
        ),
    ]
)
