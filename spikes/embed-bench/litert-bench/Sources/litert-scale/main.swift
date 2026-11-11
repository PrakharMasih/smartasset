// Phase 3, decision D5: EmbeddingGemma 2 (LiteRT-LM, GPU) over the whole COCO 5k test split, to give the vector-index comparison
// real vectors at a larger size: 5,000 image vectors, 25,000 caption vectors as queries, and 20,000 caption vectors as documents.
// Writes two dumps in the format `eval` and `real` read. Usage: litert-scale [--quick]
import BenchSupport
import Foundation
import LiteRTLM

@main
struct LiteRTScale {
    static func main() async {
        do { try await run() } catch {
            log("ERROR: \(error)")
            exit(1)
        }
    }

    enum Input: Sendable {
        case query(String), document(String), image(String)
        var content: Content {
            switch self {
            case .query(let s): .text("task: search result | query: \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
            case .document(let s): .text("title: none | text: \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
            case .image(let path): .imageFile(path)
            }
        }
    }

    static func run() async throws {
        let quick = CommandLine.arguments.contains("--quick")
        var items = try Datasets.cocoFull()
        if quick { items = Array(items.prefix(100)) }
        let outRoot = Bench.results(quick ? "litert-scale-quick" : "litert-scale")
        var perf: [String: Any] = ["runtime": "LiteRT-LM 0.19.1 (GPU), int4/int8 QAT 740M bundle", "images": items.count]
        perf["footprint_start_mb"] = physFootprintMB()

        let cache = Bench.workspace.appending(path: "work/litert-cache-litert-gpu").path    // the kernel cache the first run filled
        let config = EmbeddingEngineConfig(modelPath: Bench.models("litert/embeddinggemma-2-740m.litertlm").path, backend: .gpu,
                                           visionBackend: .gpu, audioBackend: .gpu, cacheDir: cache)
        let engine = EmbeddingEngine(config: config)
        let t0 = now()
        try await engine.initialize()
        perf["load_ms"] = now() - t0
        log("loaded in \(perf["load_ms"] ?? 0) ms")

        // Text in batches of 32. `form` decides whether a caption is embedded as a query or as a document.
        func embedTexts(_ texts: [String], document: Bool, label: String) async throws -> [[Float]] {
            var out: [[Float]] = []
            var i = 0
            let t = now()
            while i < texts.count {
                let chunk = Array(texts[i..<min(i + 32, texts.count)])
                let r = try await engine.computeEmbeddingBatch(
                    contentsBatch: chunk.map { [(document ? Input.document($0) : Input.query($0)).content] },
                    options: EmbeddingOptions(normalize: true, outputSize: 768))
                out += r.map(\.embedding)
                i += 32
                if (i / 32) % 100 == 0 { log("\(label): \(out.count)/\(texts.count)") }
            }
            perf["\(label)_seconds"] = (now() - t) / 1000
            return out
        }

        // 1. every caption as a query (5 per image); caption 0 of each image doubles as the text-to-text query
        let queryTexts = items.flatMap(\.captions)
        let queryVectors = try await embedTexts(queryTexts, document: false, label: "captions_as_queries")
        // 2. captions 1...4 as documents (the text-to-text corpus); caption 0 is the query, so a caption never finds itself
        var docTexts: [String] = [], docImage: [Int] = []
        for (i, it) in items.enumerated() { for c in it.captions.dropFirst() { docTexts.append(c); docImage.append(i) } }
        let docVectors = try await embedTexts(docTexts, document: true, label: "captions_as_documents")
        perf["footprint_after_text_mb"] = physFootprintMB()

        // 3. images at 70 tokens (the budget the plan's default would use; 140 was measured on the 500 sample)
        var imageSamples = Samples()
        var imageVectors: [[Float]] = []
        for (n, it) in items.enumerated() {
            let path = Datasets.cocoFullImage(it).path
            imageVectors.append(try await timed(&imageSamples) {
                try await engine.computeEmbedding(contents: [Input.image(path).content],
                                                  options: EmbeddingOptions(normalize: true, outputSize: 768, visionTokensPerImage: 70)).embedding
            })
            if (n + 1) % 500 == 0 { log("images: \(n + 1)/\(items.count) p50 \(imageSamples.summary["p50_ms"] ?? 0) ms") }
        }
        perf["image_budget_70"] = imageSamples.summary
        perf["footprint_peak_mb"] = peakFootprintMB()
        perf["thermal_at_end"] = thermalState()

        let runtime = "litert-lm gpu (int4/int8 QAT)"
        // text -> image: every caption finds its own image among all of them
        try Dump(task: "text -> image, COCO 5k test split (\(items.count) images, \(queryTexts.count) captions), vision budget 70", runtime: runtime,
                 queries: queryVectors, corpus: imageVectors, relevance: queryTexts.indices.map { [$0 / 5] },
                 groups: queryTexts.map { lengthBucket($0) }, queryTexts: queryTexts, perf: perf)
            .write(to: outRoot.appending(path: "coco5k_t2i_b70"))
        // text -> text: caption 0 finds the other four captions of the same image among all the other images' captions
        let firstCaptions = items.indices.map { queryVectors[$0 * 5] }
        var byImage: [Int: [Int]] = [:]
        for (d, img) in docImage.enumerated() { byImage[img, default: []].append(d) }
        try Dump(task: "caption -> other captions of the same image, COCO 5k (\(docVectors.count) documents)", runtime: runtime,
                 queries: firstCaptions, corpus: docVectors, relevance: items.indices.map { byImage[$0] ?? [] },
                 groups: items.indices.map { lengthBucket(items[$0].captions[0]) }, queryTexts: items.map { $0.captions[0] }, perf: perf)
            .write(to: outRoot.appending(path: "coco5k_t2t"))
        log("dumps written to \(outRoot.path)")
    }
}
