// swift-tools-version: 6.2
// Phase 3 research: the provider interface that keeps inference swappable between in-process and out-of-process (XPC-style),
// a stand-in child-process transport, and the benchmark that compares the two. Not shipped. Depends only on BenchSupport.
import PackageDescription

let package = Package(
    name: "provider-kit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ProviderKit", targets: ["ProviderKit"])],
    dependencies: [.package(path: "../bench-support")],
    targets: [.target(name: "ProviderKit", dependencies: [.product(name: "BenchSupport", package: "bench-support")])]
)
