// Phase 3: WhisperKit over the speech manifest. Writes the same result JSON as run_whispercpp.py.
// Usage: whisperkit-run <model-folder-name> <label> [--quick]
import BenchSupport
import CoreML
import Foundation
import WhisperKit

struct ASRItem: Decodable {
    let id: String, group: String, path: String, ref: String, language: String
    let seconds: Double
}

@main
struct WKRun {
    static func main() async {
        do { try await run() } catch {
            log("ERROR: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw NSError(domain: "usage", code: 1, userInfo: [NSLocalizedDescriptionKey: "whisperkit-run <folder> <label> [--quick]"]) }
        let folder = args[1], label = args[2], quick = args.contains("--quick")
        var items = try JSONDecoder().decode([ASRItem].self, from: Data(contentsOf: Bench.data("asr/" + (ProcessInfo.processInfo.environment["ASR_MANIFEST"] ?? "manifest.json"))))
        if quick { items = Array(items.filter { ["tts-en0", "tts-hi0", "tts-hg0", "timeline"].contains($0.id) || $0.id.hasPrefix("fleurs") }.prefix(6)) }

        var out: [String: Any] = ["engine": "WhisperKit 1.1.1 (Core ML, ANE/GPU)", "model": label, "model_folder": folder]
        out["footprint_start_mb"] = physFootprintMB()
        let t0 = now()
        let config = WhisperKitConfig(modelFolder: Bench.models("whisperkit/\(folder)").path, computeOptions: ModelComputeOptions(),
                                      verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        let kit = try await WhisperKit(config)
        out["load_ms_single"] = now() - t0
        out["footprint_after_load_mb"] = physFootprintMB()
        log("loaded \(label) in \(out["load_ms_single"] ?? 0) ms")

        var results: [[String: Any]] = []
        for item in items {
            let options = DecodingOptions(verbose: false, task: .transcribe, language: item.language, temperature: 0,
                                           wordTimestamps: item.id.hasPrefix("timeline"))   // word times only where they are scored: they cost extra
            let t = now()
            let transcription = try await kit.transcribe(audioPath: item.path, decodeOptions: options)
            let ms = now() - t
            let segments = transcription.flatMap { $0.segments }
            let words: [[String: Any]] = segments.flatMap { $0.words ?? [] }
                .map { ["w": $0.word.trimmingCharacters(in: .whitespaces), "s": Double($0.start), "e": Double($0.end)] }
            let text = transcription.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            results.append(["id": item.id, "hyp": text, "infer_ms": ms, "audio_s": item.seconds, "words": words,
                            "language": transcription.first?.language ?? ""])
            log("\(item.id) \(Int(ms)) ms")
        }
        out["items"] = results
        out["footprint_peak_mb"] = peakFootprintMB()
        out["thermal_at_end"] = thermalState()

        // Language detection (no language given) on the non-English items, to see whether the model identifies Hindi and Hinglish.
        var detected: [[String: String]] = []
        for item in items where item.group.hasPrefix("hindi") || item.group == "hinglish" {
            let options = DecodingOptions(verbose: false, task: .transcribe, language: nil, temperature: 0, usePrefillPrompt: true, detectLanguage: true)
            let r = try await kit.transcribe(audioPath: item.path, decodeOptions: options)
            detected.append(["id": item.id, "expected": item.language, "detected": r.first?.language ?? ""])
        }
        out["language_detection"] = detected
        let dest = Bench.results("asr/whisperkit-\(label).json")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: dest)
        log("written \(dest.path)")
    }
}
