// swift-tools-version: 6.2
// Phase 3: runs a command and records, while it runs, what it costs the whole machine (not just its own process).
import PackageDescription

let package = Package(
    name: "measure-bench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../bench-support")],
    targets: [.executableTarget(name: "measure-run", dependencies: [.product(name: "BenchSupport", package: "bench-support")],
                                path: "Sources/measure-run")]
)
