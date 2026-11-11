// Phase 3: EmbeddingGemma 2 through the community MLX Swift runtime. Writes dumps for the evaluator and perf.json.
// Usage: mlx-dump [--cpu] [--quick] [--budgets 70,140]   (--cpu: run every operation on the CPU; --quick: 50 images, 40 captions, to check that everything runs;
//        --budgets: vision token budgets to run, default 70,140,280 -- the CPU backend is far too slow for all three)
import BenchSupport
import EmbeddingGemma2
import Foundation
import MLX

@main
struct MLXDump {
    static func main() async {
        do { try await run() } catch {
            log("ERROR: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let quick = CommandLine.arguments.contains("--quick")
        let cpu = CommandLine.arguments.contains("--cpu")
        let budgets: [Int] = CommandLine.arguments.drop { $0 != "--budgets" }.dropFirst().first.map { $0.split(separator: ",").compactMap { Int($0) } } ?? [70, 140, 280]
        if cpu { Device.setDefault(device: Device(.cpu)) }   // not the static Device.cpu: MLX documents that as having no effect
        // Same policy as the runtime's own CLI: bound the reusable GPU buffer cache. Recorded so the memory numbers can be read fairly.
        Memory.cacheLimit = 64 * 1024 * 1024
        let outRoot = Bench.results("mlx-\(cpu ? "cpu" : "gpu")\(quick ? "-quick" : "")")
        var perf: [String: Any] = ["runtime": "EmbeddingGemma2Swift (MLX Swift 0.32.3), q8 text+vision, bf16 audio", "backend": cpu ? "cpu" : "gpu", "memory_cache_limit_mb": 64]
        perf["footprint_start_mb"] = physFootprintMB()

        // ---- load
        let t0 = now()
        let encoder = try await TextEncoder(directory: Bench.models("mlx/text-q8"))
        perf["load_text_ms"] = now() - t0
        perf["footprint_after_text_mb"] = physFootprintMB()
        var t = now()
        try await encoder.enableVision(directory: Bench.models("mlx/vision-q8"))
        perf["load_vision_ms"] = now() - t
        perf["footprint_after_vision_mb"] = physFootprintMB()
        t = now()
        try await encoder.enableAudio(directory: Bench.models("mlx/audio-bf16"))
        perf["load_audio_ms"] = now() - t
        perf["footprint_after_audio_mb"] = physFootprintMB()
        log("loaded: text \(perf["load_text_ms"] ?? 0) ms, footprint \(perf["footprint_after_audio_mb"] ?? 0) MB")

        // ---- consistency mode: a few of each input, to compare devices (a CPU run of the full sets would take hours)
        if let nArg = CommandLine.arguments.drop(while: { $0 != "--consistency" }).dropFirst().first, let n = Int(nArg) {
            let coco = Array(try Datasets.coco().prefix(n))
            let sounds = Array(try Datasets.sounds().prefix(n)), speech = Array(try Datasets.speech().prefix(n))
            var stage: [String: Double] = [:]
            var t = now()
            let texts = coco.map { $0.captions[0] }
            let q = try await encoder.encode(texts, task: .search)
            stage["text_ms_per_item"] = (now() - t) / Double(texts.count); t = now()
            var images: [[Float]] = []
            for c in coco { images.append(try await encoder.encodeImage(url: Datasets.cocoImage(c), maxSoftTokens: 70)) }
            stage["image_70_ms_per_item"] = (now() - t) / Double(coco.count); t = now()
            var audio: [[Float]] = []
            for a in sounds { audio.append(try await encoder.encodeAudio(url: Datasets.soundClip(a))) }
            for a in speech { audio.append(try await encoder.encodeAudio(url: Datasets.speechClip(a))) }
            stage["audio_ms_per_item"] = (now() - t) / Double(sounds.count + speech.count)
            perf["stage"] = stage
            perf["thermal_at_end"] = thermalState()
            log("consistency stages: \(stage)")
            // queries = captions; corpus = images then sounds then speech (the order a comparison tool pairs up)
            try Dump(task: "consistency (\(cpu ? "cpu" : "gpu"))", runtime: "mlx \(cpu ? "cpu" : "gpu")", queries: q, corpus: images + audio,
                     relevance: q.indices.map { [$0] }, groups: texts.map { _ in "all" }, queryTexts: texts, perf: perf)
                .write(to: Bench.results("mlx-consistency-\(cpu ? "cpu" : "gpu")"))
            return
        }

        // ---- datasets
        var coco = try Datasets.coco()
        if quick { coco = Array(coco.prefix(50)) }
        let captions: [(text: String, image: Int)] = coco.enumerated().flatMap { i, c in c.captions.map { ($0, i) } }
        let sounds = try Datasets.sounds()
        let categories = try Datasets.soundCategories()
        let speech = try Datasets.speech()
        let (sentences, sentenceGroup) = speechSentences(speech)

        // ---- text
        var batchSamples = Samples(), singleSamples = Samples()
        var captionVectors: [[Float]] = []
        let texts = quick ? Array(captions.prefix(40)) : captions
        var i = 0
        while i < texts.count {
            let chunk = Array(texts[i..<min(i + 32, texts.count)])
            let t = now()
            captionVectors += try await encoder.encode(chunk.map(\.text), task: .search)
            batchSamples.add((now() - t) / Double(chunk.count))      // milliseconds per text, at batch 32
            i += 32
        }
        for c in texts.prefix(100) {                                  // one at a time, like a person typing a query
            _ = try await timed(&singleSamples) { try await encoder.encode([c.text], task: .search) }
        }
        perf["text_batch32_per_text"] = batchSamples.summary
        perf["text_single"] = singleSamples.summary
        let labels = Array(Set(sounds.map(\.label))).sorted()
        let labelVectors = try await encoder.encode(labels, task: .search)
        let labelTemplateVectors = try await encoder.encode(labels.map { "the sound of \($0)" }, task: .search)
        let sentenceQuery = try await encoder.encode(sentences, task: .search)
        let sentenceDoc = try await encoder.encode(sentences, task: .document)
        perf["footprint_after_text_run_mb"] = physFootprintMB()
        log("text done")

        // ---- images at three vision budgets
        var imageVectors: [Int: [[Float]]] = [:]
        for budget in budgets {
            var s = Samples()
            var vectors: [[Float]] = []
            for item in coco {
                let url = Datasets.cocoImage(item)
                vectors.append(try await timed(&s) { try await encoder.encodeImage(url: url, maxSoftTokens: budget) })
            }
            imageVectors[budget] = vectors
            perf["image_budget_\(budget)"] = s.summary
            perf["footprint_after_images_\(budget)_mb"] = physFootprintMB()
            log("images \(budget) done: p50 \(s.summary["p50_ms"] ?? 0) ms")
        }

        // ---- audio
        var soundSamples = Samples(), speechSamples = Samples()
        var soundVectors: [[Float]] = []
        for item in (quick ? Array(sounds.prefix(40)) : sounds) {
            let url = Datasets.soundClip(item)
            soundVectors.append(try await timed(&soundSamples) { try await encoder.encodeAudio(url: url) })
        }
        var speechVectors: [[Float]] = []
        for item in speech {
            let url = Datasets.speechClip(item)
            speechVectors.append(try await timed(&speechSamples) { try await encoder.encodeAudio(url: url) })
        }
        perf["audio_5s_clip"] = soundSamples.summary
        perf["audio_speech_clip"] = speechSamples.summary
        perf["audio_speech_seconds_total"] = speech.reduce(0) { $0 + $1.seconds }
        perf["footprint_peak_mb"] = peakFootprintMB()
        perf["footprint_end_mb"] = physFootprintMB()
        perf["mlx"] = await encoder.memory().mapValues { Double($0) / 1_048_576 }
        perf["thermal_at_end"] = thermalState()
        log("audio done")

        // ---- dumps
        let r = "mlx \(cpu ? "cpu" : "gpu") (q8 text+vision, bf16 audio)"
        for budget in budgets {
            let rel = texts.map { [$0.image] }
            try Dump(task: "text -> image, COCO captions, vision budget \(budget)", runtime: r, queries: captionVectors,
                     corpus: imageVectors[budget] ?? [], relevance: rel, groups: texts.map { lengthBucket($0.text) },
                     queryTexts: texts.map(\.text), perf: perf)
                .write(to: outRoot.appending(path: "coco_t2i_b\(budget)"))
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
        log("dumps written to \(outRoot.path)")
    }
}
