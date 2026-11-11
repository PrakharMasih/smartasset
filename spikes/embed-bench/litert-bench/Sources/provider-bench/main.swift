// Phase 3: LiteRT-LM behind the provider interface; run in this process and in a child process (see ProviderKit/ProviderBench.swift).
// Usage: provider-bench [--only inproc|child]      (the child is this same executable started with --serve)
import BenchSupport
import Foundation
import LiteRTLM
import ProviderKit

final class LiteRTProvider: EmbeddingProvider, @unchecked Sendable {
    let name = "litert-lm-gpu"
    private var engine: EmbeddingEngine?

    func prepare() async throws {
        if engine != nil { return }
        let cache = Bench.workspace.appending(path: "work/litert-cache-litert-gpu").path
        let config = EmbeddingEngineConfig(modelPath: Bench.models("litert/embeddinggemma-2-740m.litertlm").path, backend: .gpu,
                                           visionBackend: .gpu, audioBackend: .gpu, cacheDir: cache)
        let e = EmbeddingEngine(config: config)
        try await e.initialize()
        engine = e
    }

    private func content(_ input: EmbeddingInput) -> Content {
        switch input {
        case .query(let s): .text("task: search result | query: \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .document(let s): .text("title: none | text: \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .image(let path, _): .imageFile(path)
        case .audio(let path): .audioFile(path)
        }
    }

    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        guard let engine else { throw ProviderError.failed("not prepared") }
        var out: [[Float]] = []
        for input in inputs {
            var tokens: Int? = nil
            if case .image(_, let t) = input { tokens = t }
            let r = try await engine.computeEmbedding(contents: [content(input)],
                                                      options: EmbeddingOptions(normalize: true, outputSize: 768, visionTokensPerImage: tokens))
            out.append(r.embedding)
        }
        return out
    }

    func shutdown() async { await engine?.close(); engine = nil }
    func footprintMB() async -> Double { physFootprintMB() }
}

ProviderBench.main(name: "litert-gpu") { LiteRTProvider() }
