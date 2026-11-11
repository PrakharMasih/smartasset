// Phase 3: EmbeddingGemma 2 (community MLX runtime, GPU) over the whole COCO 5k test split, the counterpart of litert-scale: the same inputs, the same
// vision budget (70 tokens), the same two dumps, so the two runtimes are scored on the same 5,000 images, 25,000 captions and 20,000 documents.
// Usage: mlx-scale [--quick] [--budget 70|140|280] [--thumb <edge>]
//   --budget  vision soft tokens per image (default 70, the Phase 3 setting)
//   --thumb   first shrink each photo to this longest edge with ImageIO, as the app does with its grid thumbnail (Phase 4 accuracy spike);
//             with --budget or --thumb only the text -> image dump is written (the caption dump does not depend on them)
import BenchSupport
import CoreGraphics
import ImageIO
import EmbeddingGemma2
import Foundation
import MLX

@main
struct MLXScale {
    static func main() async {
        do { try await run() } catch {
            log("ERROR: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        let quick = args.contains("--quick")
        func option(_ name: String) -> Int? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } }
        let budget = option("--budget") ?? 70
        let thumb = option("--thumb")
        let imagesOnly = option("--budget") != nil || thumb != nil
        let label = "b\(budget)" + (thumb.map { "_thumb\($0)" } ?? "")
        Memory.cacheLimit = 64 * 1024 * 1024
        var items = try Datasets.cocoFull()
        if quick { items = Array(items.prefix(100)) }
        let outRoot = Bench.results(quick ? "mlx-scale-quick" : "mlx-scale")
        var perf: [String: Any] = ["runtime": "EmbeddingGemma2Swift (MLX Swift 0.32.3), q8 text+vision, bf16 audio", "images": items.count]
        perf["footprint_start_mb"] = physFootprintMB()
        let t0 = now()
        let encoder = try await TextEncoder(directory: Bench.models("mlx/text-q8"))
        try await encoder.enableVision(directory: Bench.models("mlx/vision-q8"))
        perf["load_ms"] = now() - t0
        perf["footprint_after_load_mb"] = physFootprintMB()

        func embedTexts(_ texts: [String], task: EmbeddingTask, label: String) async throws -> [[Float]] {
            var out: [[Float]] = []
            var i = 0
            let t = now()
            while i < texts.count {
                out += try await encoder.encode(Array(texts[i..<min(i + 32, texts.count)]), task: task)
                i += 32
                if (i / 32) % 100 == 0 { log("\(label): \(out.count)/\(texts.count)") }
            }
            perf["\(label)_seconds"] = (now() - t) / 1000
            return out
        }

        let queryTexts = items.flatMap(\.captions)
        let queryVectors = try await embedTexts(queryTexts, task: .search, label: "captions_as_queries")
        var docTexts: [String] = [], docImage: [Int] = []
        if !imagesOnly { for (i, it) in items.enumerated() { for c in it.captions.dropFirst() { docTexts.append(c); docImage.append(i) } } }
        let docVectors = try await embedTexts(docTexts, task: .document, label: "captions_as_documents")
        perf["footprint_after_text_mb"] = physFootprintMB()

        var imageSamples = Samples()
        var imageVectors: [[Float]] = []
        for (n, it) in items.enumerated() {
            let url = Datasets.cocoFullImage(it)
            if let thumb {
                let small = try thumbnail(url, edge: thumb)
                imageVectors.append(try await timed(&imageSamples) {
                    try await encoder.encodeImage(try ImageProcessor.prepare(small, maxSoftTokens: budget))
                })
            } else {
                imageVectors.append(try await timed(&imageSamples) { try await encoder.encodeImage(url: url, maxSoftTokens: budget) })
            }
            if (n + 1) % 500 == 0 { log("images: \(n + 1)/\(items.count) p50 \(imageSamples.summary["p50_ms"] ?? 0) ms") }
        }
        perf["image_budget_\(budget)"] = imageSamples.summary
        if let thumb { perf["thumbnail_edge"] = thumb }
        perf["footprint_peak_mb"] = peakFootprintMB()
        perf["mlx_memory_mb"] = await encoder.memory().mapValues { Double($0) / 1_048_576 }
        perf["thermal_at_end"] = thermalState()

        let runtime = "mlx gpu (q8 text+vision)"
        try Dump(task: "text -> image, COCO 5k test split (\(items.count) images, \(queryTexts.count) captions), vision budget \(budget)\(thumb.map { ", from a \($0) px thumbnail" } ?? "")", runtime: runtime,
                 queries: queryVectors, corpus: imageVectors, relevance: queryTexts.indices.map { [$0 / 5] },
                 groups: queryTexts.map { lengthBucket($0) }, queryTexts: queryTexts, perf: perf)
            .write(to: outRoot.appending(path: "coco5k_t2i_\(label)"))
        if imagesOnly {
            log("dump written to \(outRoot.path)")
            return
        }
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

/// The photo shrunk to `edge` pixels on its longest side by ImageIO (as the app's thumbnails are), as opaque sRGB bytes.
func thumbnail(_ url: URL, edge: Int) throws -> RGBImage {
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: edge,
                                    kCGImageSourceCreateThumbnailWithTransform: true]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.fileReadCorruptFile) }
    let (w, h) = (image.width, image.height)
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { throw CocoaError(.fileReadCorruptFile) }
    var rgb = [UInt8](repeating: 0, count: w * h * 3)
    for i in 0..<(w * h) { for c in 0..<3 { rgb[i * 3 + c] = rgba[i * 4 + c] } }
    return try RGBImage(width: w, height: h, bytes: rgb)
}
