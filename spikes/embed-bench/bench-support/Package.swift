// swift-tools-version: 6.2
// Phase 3 research harness shared by the runtime comparisons. Not shipped. No dependencies.
import PackageDescription

let package = Package(
    name: "bench-support",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BenchSupport", targets: ["BenchSupport"])],
    targets: [.target(name: "BenchSupport")]
)
