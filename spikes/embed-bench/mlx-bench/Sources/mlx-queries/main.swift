// Phase 4 accuracy spike: does wording a short question differently help search by meaning? Text only: the pictures are
// an existing mlx-scale dump (COCO 5k), so each run takes a minute or two.
// Usage: mlx-queries <dump folder under results/, e.g. mlx-scale/coco5k_t2i_b140>
//
// Ground truth for one-word questions is the self-test's: a photo is relevant when one of its five captions contains the word
// (or its plural). The nonsense lists are the self-test's too. A wording is only worth keeping if it lifts the one-word
// questions without lifting the nonsense along with them (the app rejects a question whose best match is under a cut).
import BenchSupport
import EmbeddingGemma2
import Foundation
import MLX

let words = ["dog", "cat", "pizza", "giraffe", "train", "bus", "airplane", "bicycle", "surfboard", "umbrella", "clock", "bench", "elephant", "zebra",
             "kitchen", "beach", "snow", "tennis", "baseball", "motorcycle", "sandwich", "bird", "boat", "horse", "truck", "laptop", "vase", "bear", "sheep", "skateboard"]
let nonsense = ["zzzzqq", "asdkjh qwe", "xylophone quantum", "lorem ipsum dolor", "qqqq", "the", "blorp", "9482716", "hello", "kubernetes deployment yaml",
                "invoice 2023", "meeting notes", "quarterly revenue", "password reset", "xkcd", "aaaa bbbb cccc", "oiuytrewq", "spreadsheet formula", "tax return", "zzz"]
let oneWordNonsense = ["blorp", "zzzz", "qwerty", "asdf", "xylophone", "foobar", "lorem", "the", "and", "of", "invoice", "password", "spreadsheet", "meeting", "tax"]

/// A wording: the texts a question becomes (their vectors are averaged), applied only to questions of at most three words.
struct Variant: Sendable { let name: String; let forms: [@Sendable (String) -> String] }
let variants = [
    Variant(name: "as typed", forms: [{ $0 }]),
    Variant(name: "a photo of", forms: [{ "a photo of \($0)" }]),
    Variant(name: "avg(typed, photo of)", forms: [{ $0 }, { "a photo of \($0)" }]),
    Variant(name: "avg(typed, photo, picture showing)", forms: [{ $0 }, { "a photo of \($0)" }, { "a picture showing \($0)" }]),
]

@main
struct MLXQueries {
    static func main() async {
        do { try await run() } catch {
            log("ERROR: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        guard CommandLine.arguments.count > 1 else { log("usage: mlx-queries <dump under results/>"); exit(2) }
        let dumpDir = Bench.results(CommandLine.arguments[1])
        let raw = try Data(contentsOf: dumpDir.appending(path: "corpus.f32"))
        let dims = 768
        let floats: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = floats.count / dims
        let items = try Datasets.cocoFull()
        guard items.count == n else { log("corpus has \(n) pictures, captions list \(items.count)"); exit(2) }
        let lowered = items.map { $0.captions.joined(separator: " ").lowercased() }

        Memory.cacheLimit = 64 * 1024 * 1024
        let encoder = try await TextEncoder(directory: Bench.models("mlx/text-q8"))

        func scores(_ q: [Float]) -> [Float] {
            (0..<n).map { i in
                var s: Float = 0
                let base = i * dims
                for d in 0..<dims { s += floats[base + d] * q[d] }
                return s
            }
        }
        func question(_ text: String, _ v: Variant) async throws -> [Float] {
            let short = text.split(separator: " ").count <= 3
            let forms = short ? v.forms.map { $0(text) } : [text]
            let vectors = try await encoder.encode(forms, task: .search)
            var sum = [Float](repeating: 0, count: dims)
            for vec in vectors { for d in 0..<dims { sum[d] += vec[d] } }
            let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
            return sum.map { $0 / max(norm, 1e-9) }
        }
        func quantiles(_ v: [Float]) -> String {
            let s = v.sorted()
            func q(_ p: Double) -> Float { s[min(s.count - 1, Int(Double(s.count) * p))] }
            return String(format: "min %.3f median %.3f max %.3f", s.first ?? 0, q(0.5), s.last ?? 0)
        }

        print("pictures: \(n) from \(CommandLine.arguments[1])")
        for v in variants {
            var ap = 0.0, p10 = 0.0, bandP = 0.0, bandR = 0.0, used = 0
            var wordTops: [Float] = []
            for w in words {
                let relevant = Set(lowered.indices.filter { lowered[$0].range(of: "\\b\(w)s?\\b", options: .regularExpression) != nil })
                guard relevant.count >= 5 else { continue }
                let s = scores(try await question(w, v))
                let order = s.indices.sorted { s[$0] > s[$1] }
                used += 1
                wordTops.append(s[order[0]])
                var hits = 0, sumPrec = 0.0
                for (rank, i) in order.prefix(1000).enumerated() where relevant.contains(i) {
                    hits += 1
                    sumPrec += Double(hits) / Double(rank + 1)
                }
                ap += sumPrec / Double(min(relevant.count, 1000))
                p10 += Double(order.prefix(10).filter { relevant.contains($0) }.count) / 10
                let kept = order.prefix { s[$0] >= s[order[0]] - 0.08 }
                let good = kept.filter { relevant.contains($0) }.count
                bandP += Double(good) / Double(max(1, kept.count))
                bandR += Double(good) / Double(relevant.count)
            }
            var junk: [Float] = [], junkWord: [Float] = []
            for t in nonsense { junk.append(scores(try await question(t, v)).max() ?? 0) }
            for t in oneWordNonsense { junkWord.append(scores(try await question(t, v)).max() ?? 0) }
            let k = Double(used)
            print("\n== \(v.name)")
            print(String(format: "one-word (%d words): AP@1000 %.3f  P@10 %.3f  band 0.08: precision %.2f recall %.2f", used, ap / k, p10 / k, bandP / k, bandR / k))
            print("  best match, one-word questions: \(quantiles(wordTops))")
            print("  best match, sentence nonsense:  \(quantiles(junk))")
            print("  best match, one-word nonsense:  \(quantiles(junkWord))")
            // Separation: how far the weakest real one-word question sits above the strongest nonsense.
            print(String(format: "  margin (weakest real word - strongest nonsense): %.3f", (wordTops.min() ?? 0) - max(junk.max() ?? 0, junkWord.max() ?? 0)))
        }
    }
}
