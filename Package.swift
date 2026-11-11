// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Search by meaning (Phase 4) runs EmbeddingGemma 2 on MLX Swift. Those are third-party packages: they are used only from
// the pinned local clones that Phase 3 reviewed (versions and commits in phase3/PINS.md), never fetched by this build.
// Where the clones are: SA_PHASE3_DIR, else ~/Library/Developer/SmartAsset/phase3. Without them, or with SA_NO_MLX=1, the
// app still builds and runs: search by meaning is simply off and every search is the keyword search.
let phase3 = Context.environment["SA_PHASE3_DIR"] ?? NSHomeDirectory() + "/Library/Developer/SmartAsset/phase3"
let useMLX = Context.environment["SA_NO_MLX"] == nil
    && FileManager.default.fileExists(atPath: phase3 + "/eg2/Package.swift")
    && FileManager.default.fileExists(atPath: phase3 + "/work/deps/mlx-swift/Package.swift")
// The runtime's manifest and its dependencies' manifests name these by URL. Each pinned local clone takes the place of
// its URL (same package identity), so resolving needs no network.
let mlxPackages: [Package.Dependency] = useMLX
    ? [.package(path: phase3 + "/eg2")] + ["mlx-swift", "swift-transformers", "swift-huggingface", "swift-jinja", "swift-collections",
                                           "swift-crypto", "swift-asn1", "swift-numerics", "eventsource", "yyjson"]
        .map { .package(path: phase3 + "/work/deps/" + $0) }
    : []
let mlxProducts: [Target.Dependency] = useMLX
    ? [.product(name: "EmbeddingGemma2", package: "eg2"), .product(name: "MLX", package: "mlx-swift")]
    : []

// The Rust core is built by tools/gen-bridge.sh into core/target/release (plan D1, docs/BRIDGE.md).
let rustLib = Context.packageDirectory + "/core/target/release"

let package = Package(
    name: "SmartAsset",
    platforms: [.macOS(.v14)],
    dependencies: mlxPackages,
    targets: [
        // C header + module map for the Rust static library (generated).
        .systemLibrary(name: "sa_ffiFFI"),
        // UniFFI-generated Swift (generated; never edited by hand).
        .target(
            name: "CoreBridgeGenerated",
            dependencies: ["sa_ffiFFI"],
            linkerSettings: [
                .unsafeFlags(["-L", rustLib, "-lsa_ffi"]),
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("iconv"),
            ]
        ),
        // Thin, typed Swift layer over the generated code.
        .target(name: "CoreBridge", dependencies: ["CoreBridgeGenerated"]),
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "SmartAssetKit", dependencies: ["CoreBridge"]),
        // Batch workers: ImageIO / AVFoundation media decoding (plan §6.5).
        .target(name: "Workers", dependencies: ["CoreBridge", "SmartAssetKit"]),
        // The model runtime (EmbeddingGemma 2 on MLX Swift) behind the `EmbeddingModel` protocol. The only target that
        // touches MLX; without the pinned clones it holds a stand-in that reports "not available".
        .target(
            name: "Embedding",
            dependencies: ["CoreBridge", "Workers", "SmartAssetKit"] + mlxProducts,
            swiftSettings: useMLX ? [.define("SA_MLX")] : []
        ),
        // Generated sample photos, clips and sounds, for tests and for snapshot mode.
        .target(name: "DemoMedia"),
        .executableTarget(
            name: "SmartAsset",
            dependencies: ["CoreBridge", "SmartAssetKit", "Workers", "Embedding", "DemoMedia"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Macro-free test runner: `swift test` needs Xcode's Testing/XCTest plugins, which Command Line Tools lack.
        // Run with tools/test.sh. It exits non-zero when any check fails.
        .executableTarget(name: "SATests", dependencies: ["CoreBridge", "Workers", "SmartAssetKit", "DemoMedia"]),
    ]
)
