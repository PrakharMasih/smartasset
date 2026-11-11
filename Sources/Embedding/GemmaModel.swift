// EmbeddingGemma 2 on MLX Swift (the owner's choice, PLAN §16, 2026-11-07), through the community package pinned in
// phase3/PINS.md. Text and pictures share one 768-number space, so a sentence lands near the pictures it describes.
//
// Facts this file relies on, all measured or read in Phase 3 (docs/research/phase3-model-spikes.md):
//  * queries use the model's "search" prompt and pictures the vision tower, both at 768 numbers (128 is never used);
//  * the model runs in its own quantised bf16 form, never f16 (that breaks it); the vectors Rust stores are f16;
//  * a picture is given at most 140 "soft tokens" (the owner's choice, 2026-11-08: up to about twice the time for more
//    detail). On 5,000 COCO photos, from a 512 px thumbnail: hit@1 0.537 -> 0.566, hit@10 0.851 -> 0.868, 74 -> 116 ms a
//    picture (docs/research/phase4-semantic-search.md, "Accuracy"). Larger inputs than the thumbnail gave nothing more;
//  * results on public photo sets only. Nothing here is validated on creator media, so it is not release-approved.
#if SA_MLX
import CoreBridge
import EmbeddingGemma2
import Foundation
import Workers

final class GemmaModel: EmbeddingModel {
    static let softTokens = 140
    static let dimensions = 768
    /// What this model's similarities mean, measured on public photographs (COCO) through the real app at 140 picture
    /// tokens, 2026-11-08 (docs/research/phase4-semantic-search.md; the self-test "semantic search" repeats it and guards it):
    ///  * in a library of 558 files the best match of a real question scored 0.65 to 0.85 (full sentences) and 0.71 to 0.77
    ///    (one word); of nonsense, 0.59 to 0.70. At 0.70, 96 % of captions, every one-word question and none of the 35
    ///    nonsense questions are answered by meaning (at 70 tokens, 7 % of one-word nonsense got through);
    ///  * for one-word questions, files within 0.08 of the best match have precision 0.65 and recall 0.93 (0.05: 0.90 and 0.81;
    ///    0.12: 0.23 and 0.99). Ranking puts the best first, so the band only decides how long the tail is.
    /// **Unvalidated on creator media**, so a first measurement, not a release bar.
    static let minMatch: Float = 0.70
    static let band: Float = 0.08
    /// A2: a file stays in a group of similar copies only if its picture is at least this close to the group's first file.
    /// Measured 2026-11-09 on 200 real photos (self-test "copies by meaning"): resized, re-encoded, brighter, lower-contrast
    /// and 5–20 % cropped copies scored 0.934 or more, grayscale copies 0.851 or more, and the closest *different* photo
    /// 0.931 at most (p95 0.907). At 0.90, 99.7 % of copies stay and 7.5 % of the closest different photos would pass (those
    /// are only ever compared inside a group the picture fingerprints already formed).
    static let copyMatch: Float = 0.90
    /// C1: a file shows a label word when its picture is at least this close to the word. Measured 2026-11-09 on 500 COCO
    /// photos and 30 single words, with "a caption uses the word" as ground truth (self-test "labels"): 0.66 gives precision
    /// 0.73 and recall 0.90, **0.68 gives 0.90 and 0.81**, 0.70 gives 0.96 and 0.62. Captions are incomplete, so precision is
    /// understated. Only single words were measured; the label list uses single words for that reason.
    var labelMatch: Float? { 0.68 }

    private let encoder: TextEncoder
    private let gate = ModelGate()
    let config: ModelConfigDto

    init(directory: URL) async throws {
        encoder = try await TextEncoder(directory: directory.appending(path: "text-q8", directoryHint: .isDirectory))
        try await encoder.enableVision(directory: directory.appending(path: "vision-q8", directoryHint: .isDirectory))
        config = ModelConfigDto(
            id: "embeddinggemma2-mlx-q8-768-soft\(Self.softTokens)-v1",
            model: "EmbeddingGemma 2",
            version: "text-q8 + vision-q8 weights, mlx-swift 0.32.3",
            modality: "image",
            dims: UInt32(Self.dimensions),
            preprocessing: "thumbnail up to 512 px, \(Self.softTokens) soft tokens; video: one frame per scene (picture changes, 3 to 16), with its time",
            minMatch: Self.minMatch,
            band: Self.band,
            copyMatch: Self.copyMatch
        )
    }

    func embed(query: String) async throws -> [Float] {
        try await gate.run {
            guard let vector = try await encoder.encode([query], task: .search, dimensions: Self.dimensions).first else {
                throw SemanticModelError.disabled
            }
            return vector
        }
    }

    func embed(imageFile: URL) async throws -> [Float] {
        try await gate.run { try await encoder.encodeImage(url: imageFile, maxSoftTokens: Self.softTokens, dimensions: Self.dimensions) }
    }

    func embed(rgb: [UInt8], width: Int, height: Int) async throws -> [Float] {
        let image = try RGBImage(width: width, height: height, bytes: rgb)
        let prepared = try ImageProcessor.prepare(image, maxSoftTokens: Self.softTokens)
        return try await gate.run { try await encoder.encodeImage(prepared, dimensions: Self.dimensions) }
    }

    func close() async { await gate.close() }
}

/// Counts the calls running in the model so quitting can wait for them (see `EmbeddingModel.close`).
private actor ModelGate {
    private var running = 0
    private var closed = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        guard !closed else { throw SemanticModelError.disabled }
        running += 1
        defer {
            running -= 1
            if running == 0, closed { for c in waiting { c.resume() }; waiting = [] }
        }
        return try await body()
    }

    func close() async {
        closed = true
        guard running > 0 else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}
#endif
