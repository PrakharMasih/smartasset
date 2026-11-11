// Phase 3: EmbeddingGemma 2 through LiteRT-LM (Google). Writes the same dumps as mlx-dump.
// Usage: litert-dump [--cpu] [--quick]
import BenchSupport
import Foundation
import LiteRTLM

@main
struct LiteRTDump {
    static func main() async {
        do { try await run() } catch {
            log("ERROR: \(error)")
            exit(1)
        }
    }

    /// What to embed, as plain values: the non-Sendable `Content` is built inside each call so it never crosses an isolation boundary.
    enum Input: Sendable {
        case query(String), document(String), image(String), audio(String)
        var content: Content {
            switch self {
            case .query(let s): .text("task: search result | query: \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
            case .document(let s): .text("title: none | text: \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
            case .image(let path): .imageFile(path)
            case .audio(let path): .audioFile(path)
            }
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        let cpu = args.contains("--cpu"), quick = args.contains("--quick")
        let name = cpu ? "litert-cpu" : "litert-gpu"
        let outRoot = Bench.results(quick ? "\(name)-quick" : name)
        let backend: Backend = cpu ? .cpu() : .gpu
        var perf: [String: Any] = ["runtime": "LiteRT-LM 0.19.1 (\(cpu ? "CPU" : "GPU")), int4/int8 QAT 740M bundle", "backend": cpu ? "cpu" : "gpu"]
        perf["footprint_start_mb"] = physFootprintMB()

        // ---- load (text, vision and audio towers on the same backend)
        let cache = Bench.workspace.appending(path: "work/litert-cache-\(name)").path
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let config = EmbeddingEngineConfig(modelPath: Bench.models("litert/embeddinggemma-2-740m.litertlm").path, backend: backend,
                                           visionBackend: backend, audioBackend: backend, cacheDir: cache)
        let engine = EmbeddingEngine(config: config)
        let t0 = now()
        try await engine.initialize()
        perf["load_ms_first"] = now() - t0           // includes compiling kernels the first time (cache empty on a first run)
        perf["footprint_after_load_mb"] = physFootprintMB()
        log("loaded in \(perf["load_ms_first"] ?? 0) ms, footprint \(perf["footprint_after_load_mb"] ?? 0) MB")

        func embed(_ input: Input, image tokens: Int? = nil) async throws -> [Float] {
            try await engine.computeEmbedding(contents: [input.content],
                                              options: EmbeddingOptions(normalize: true, outputSize: 768, visionTokensPerImage: tokens)).embedding
        }

        var coco = try Datasets.coco()
        if quick { coco = Array(coco.prefix(50)) }
        let captions: [(text: String, image: Int)] = coco.enumerated().flatMap { i, c in c.captions.map { ($0, i) } }
        let sounds = try Datasets.sounds()
        let categories = try Datasets.soundCategories()
        let speech = try Datasets.speech()
        let (sentences, sentenceGroup) = speechSentences(speech)

        // ---- text: one request at a time, and batches of 32
        let texts = quick ? Array(captions.prefix(40)) : captions
        var singleSamples = Samples(), batchSamples = Samples()
        var captionVectors: [[Float]] = []
        var i = 0
        while i < texts.count {
            let chunk = Array(texts[i..<min(i + 32, texts.count)])
            let t = now()
            let responses = try await engine.computeEmbeddingBatch(contentsBatch: chunk.map { [Input.query($0.text).content] },
                                                                   options: EmbeddingOptions(normalize: true, outputSize: 768))
            batchSamples.add((now() - t) / Double(chunk.count))
            captionVectors += responses.map(\.embedding)
            i += 32
        }
        for c in texts.prefix(100) { _ = try await timed(&singleSamples) { try await embed(.query(c.text)) } }
        perf["text_batch32_per_text"] = batchSamples.summary
        perf["text_single"] = singleSamples.summary
        let labels = Array(Set(sounds.map(\.label))).sorted()
        var labelVectors: [[Float]] = [], labelTemplateVectors: [[Float]] = [], sentenceQuery: [[Float]] = [], sentenceDoc: [[Float]] = []
        for l in labels { labelVectors.append(try await embed(.query(l))) }
        for l in labels { labelTemplateVectors.append(try await embed(.query("the sound of \(l)"))) }
        for s in sentences { sentenceQuery.append(try await embed(.query(s))) }
        for s in sentences { sentenceDoc.append(try await embed(.document(s))) }
        perf["footprint_after_text_run_mb"] = physFootprintMB()
        log("text done")

        // ---- images at the two budgets this runtime supports
        var imageVectors: [Int: [[Float]]] = [:]
        for budget in [70, 140] {
            var s = Samples()
            var vectors: [[Float]] = []
            for item in coco {
                let path = Datasets.cocoImage(item).path
                vectors.append(try await timed(&s) { try await embed(.image(path), image: budget) })
            }
            imageVectors[budget] = vectors
            perf["image_budget_\(budget)"] = s.summary
            perf["footprint_after_images_\(budget)_mb"] = physFootprintMB()
            log("images \(budget) done: p50 \(s.summary["p50_ms"] ?? 0) ms")
        }

        // ---- audio
        var soundSamples = Samples(), speechSamples = Samples()
        var soundVectors: [[Float]] = [], speechVectors: [[Float]] = []
        for item in (quick ? Array(sounds.prefix(40)) : sounds) {
            let path = Datasets.soundClip(item).path
            soundVectors.append(try await timed(&soundSamples) { try await embed(.audio(path)) })
        }
        for item in speech {
            let path = Datasets.speechClip(item).path
            speechVectors.append(try await timed(&speechSamples) { try await embed(.audio(path)) })
        }
        perf["audio_5s_clip"] = soundSamples.summary
        perf["audio_speech_clip"] = speechSamples.summary
        perf["audio_speech_seconds_total"] = speech.reduce(0) { $0 + $1.seconds }
        perf["footprint_peak_mb"] = peakFootprintMB()
        perf["footprint_end_mb"] = physFootprintMB()
        perf["thermal_at_end"] = thermalState()
        log("audio done")

        // ---- dumps (same sets as mlx-dump)
        let r = "litert-lm \(cpu ? "cpu" : "gpu") (int4/int8 QAT)"
        for budget in [70, 140] {
            try Dump(task: "text -> image, COCO captions, vision budget \(budget)", runtime: r, queries: captionVectors,
                     corpus: imageVectors[budget] ?? [], relevance: texts.map { [$0.image] }, groups: texts.map { lengthBucket($0.text) },
                     queryTexts: texts.map(\.text), perf: perf).write(to: outRoot.appending(path: "coco_t2i_b\(budget)"))
        }
        let soundRelevance = labels.map { l in sounds.indices.filter { sounds[$0].label == l && $0 < soundVectors.count } }
        let soundGroups = labels.map { l in sounds.first { $0.label == l }.flatMap { categories[$0.file] } ?? "?" }
        try Dump(task: "text -> sound, ESC-50 class names", runtime: r, queries: labelVectors, corpus: soundVectors, relevance: soundRelevance,
                 groups: soundGroups, queryTexts: labels, perf: perf).write(to: outRoot.appending(path: "esc_t2s"))
        try Dump(task: "text -> sound, ESC-50 'the sound of ...'", runtime: r, queries: labelTemplateVectors, corpus: soundVectors,
                 relevance: soundRelevance, groups: soundGroups, queryTexts: labels.map { "the sound of \($0)" }, perf: perf)
            .write(to: outRoot.appending(path: "esc_t2s_template"))
        let clipsOfSentence = sentences.map { s in speech.indices.filter { speech[$0].text == s } }
        try Dump(task: "text -> speech clip (generated speech; English, Hindi, Hinglish)", runtime: r, queries: sentenceQuery, corpus: speechVectors,
                 relevance: clipsOfSentence, groups: sentenceGroup, queryTexts: sentences, perf: perf).write(to: outRoot.appending(path: "speech_t2a"))
        let sentenceIndex = Dictionary(uniqueKeysWithValues: sentences.enumerated().map { ($1, $0) })
        try Dump(task: "speech clip -> text (generated speech; 5 voice/noise groups)", runtime: r, queries: speechVectors, corpus: sentenceDoc,
                 relevance: speech.map { [sentenceIndex[$0.text] ?? 0] }, groups: speech.map(\.group),
                 queryTexts: speech.map { "\($0.voice): \($0.text)" }, perf: perf).write(to: outRoot.appending(path: "speech_a2t"))
        await engine.close()
        log("dumps written to \(outRoot.path)")
    }
}
