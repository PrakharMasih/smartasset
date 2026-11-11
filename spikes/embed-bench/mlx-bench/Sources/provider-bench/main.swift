// Phase 3: the MLX runtime behind the provider interface; run in this process and in a child process.
// Usage: provider-bench [--only inproc|child]      (the child is this same executable started with --serve)
// Image preparation (decode, resize, patch) is done here, outside the runtime's serial actor, so that one request's preparation can overlap
// another request's GPU work: that is the only way this runtime can use more than one request in flight.
import BenchSupport
import EmbeddingGemma2
import Foundation
import MLX
import ProviderKit

final class MLXProvider: EmbeddingProvider, @unchecked Sendable {
    let name = "mlx-gpu"
    private var encoder: TextEncoder?

    func prepare() async throws {
        if encoder != nil { return }
        Memory.cacheLimit = 64 * 1024 * 1024
        let e = try await TextEncoder(directory: Bench.models("mlx/text-q8"))
        try await e.enableVision(directory: Bench.models("mlx/vision-q8"))
        try await e.enableAudio(directory: Bench.models("mlx/audio-bf16"))
        encoder = e
    }

    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        guard let encoder else { throw ProviderError.failed("not prepared") }
        // Image preparation runs concurrently (it is plain CPU work); the encoder then runs the forward passes one at a time.
        let prepared: [Int: PreparedImage] = try await withThrowingTaskGroup(of: (Int, PreparedImage).self) { group in
            for (i, input) in inputs.enumerated() {
                if case .image(let path, let tokens) = input {
                    group.addTask { (i, try ImageProcessor.prepare(try RGBImage.load(URL(fileURLWithPath: path)), maxSoftTokens: tokens)) }
                }
            }
            var all: [Int: PreparedImage] = [:]
            for try await (i, p) in group { all[i] = p }
            return all
        }
        var out: [[Float]] = []
        for (i, input) in inputs.enumerated() {
            switch input {
            case .query(let s): out += try await encoder.encode([s], task: .search)
            case .document(let s): out += try await encoder.encode([s], task: .document)
            case .image: out.append(try await encoder.encodeImage(prepared[i]!))
            case .audio(let path): out.append(try await encoder.encodeAudio(url: URL(fileURLWithPath: path)))
            }
        }
        return out
    }

    func shutdown() async {
        await encoder?.disableVision(); await encoder?.disableAudio(); encoder = nil
        Memory.clearCache()
    }
    func footprintMB() async -> Double { physFootprintMB() }
}

ProviderBench.main(name: "mlx-gpu") { MLXProvider() }
