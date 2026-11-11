// One file's worth of embedding work (Phase 4): pictures from their grid thumbnail, videos from one frame per scene
// (S2), each with its place in the video.
// The model is behind `EmbeddingModel`; this file only decides what to show it.
import AVFoundation
import CoreBridge
import CoreGraphics
import Foundation
import SmartAssetKit

public enum EmbeddingProcessor {
    /// A video is looked at in a tiny grey picture of this size at each candidate instant, to find where the scenes change.
    static let signatureSize = (width: 16, height: 12)
    /// How close (seconds) the frame handed to the model must be to the scene's instant.
    static let sceneTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
    /// The longest edge of a video frame handed to the model, the size of a picture's grid thumbnail. Measured on 5,000
    /// COCO photos at 140 picture tokens: 640 px originals and 512 px thumbnails gave the same accuracy (hit@1 0.567 and
    /// 0.566), so larger inputs only cost decoding time (docs/research/phase4-semantic-search.md, "Accuracy").
    static let frameEdge: CGFloat = 512

    static func timeout(for kind: MediaKind) -> Duration {
        switch kind {
        case .video: .seconds(120)
        case .image, .audio: .seconds(60)
        }
    }

    public static func process(_ task: EmbeddingTaskDto, model: any EmbeddingModel) async -> EmbeddingOutcomeDto {
        do {
            switch task.kind {
            case .image:
                guard let thumb = task.thumbPath else { throw MediaFailure.unsupported("This picture has no thumbnail yet.") }
                return .done(vectors: [try await model.embed(imageFile: URL(fileURLWithPath: thumb))], timesMs: [])
            case .video:
                var vectors: [[Float]] = []
                var times: [Int64] = []
                for scene in try await scenes(of: task) {
                    try Task.checkCancellation()
                    vectors.append(try await model.embed(rgb: scene.frame.bytes, width: scene.frame.width, height: scene.frame.height))
                    times.append(scene.milliseconds)
                }
                // A video whose frames cannot be read is still described by its poster (its place is unknown).
                if vectors.isEmpty, let thumb = task.thumbPath {
                    vectors.append(try await model.embed(imageFile: URL(fileURLWithPath: thumb)))
                    times = []
                }
                guard !vectors.isEmpty else { throw MediaFailure.unsupported("This video has no picture to describe.") }
                return .done(vectors: vectors, timesMs: times)
            case .audio:
                throw MediaFailure.unsupported("Sounds are not searched by meaning yet.")
            }
        } catch is CancellationError {
            return .failed(class: .transient, message: "Stopped before it finished.")
        } catch let failure as MediaFailure {
            let (errorClass, message) = ErrorClassifier.classify(failure)
            return .failed(class: errorClass, message: message)
        } catch {
            // Anything else came from the model or from reading a file: the batch carries on without this one.
            return .failed(class: Task.isCancelled ? .transient : .modelFailure, message: error.userMessage)
        }
    }

    /// Like `process`, but a decoder that hangs on a damaged file cannot stall the batch.
    public static func processWithTimeout(_ task: EmbeddingTaskDto, model: any EmbeddingModel) async -> EmbeddingOutcomeDto {
        let limit = timeout(for: task.kind)
        return await withTaskGroup(of: EmbeddingOutcomeDto.self) { group in
            group.addTask { await process(task, model: model) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .failed(class: .transient, message: "Reading this file took too long.")
            }
            let first = await group.next() ?? .failed(class: .transient, message: "No answer.")
            group.cancelAll()
            return first
        }
    }

    // MARK: - Video frames

    struct Frame: Sendable {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    /// One scene of a video: where it starts and the frame that describes it.
    struct Scene: Sendable {
        let milliseconds: Int64
        let frame: Frame
    }

    /// The scenes of a video: it is sampled at evenly spaced instants as tiny grey pictures, `SceneSelector` says where the
    /// picture changes, and one frame per scene is decoded at the size handed to the model. Empty when it has no picture.
    private static func scenes(of task: EmbeddingTaskDto) async throws -> [Scene] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: task.path))
        guard try await asset.load(.isReadable) else { throw MediaFailure.corrupt("This file is not readable as media.") }
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return [] }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw MediaFailure.corrupt("This video has no length.")
        }
        let candidates = SceneSelector.candidateTimes(duration: duration.seconds)
        var seen: [Double] = []
        var signatures: [[UInt8]] = []
        let scan = AVAssetImageGenerator(asset: asset)
        scan.appliesPreferredTrackTransform = true
        scan.maximumSize = CGSize(width: 96, height: 96)
        // Close to the instant, not just any keyframe: a long-GOP video has few keyframes, and a frame from the wrong scene
        // would hide the cut.
        scan.requestedTimeToleranceBefore = sceneTolerance
        scan.requestedTimeToleranceAfter = sceneTolerance
        for time in candidates {
            try Task.checkCancellation()
            guard let image = try? await scan.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
                  let signature = grey(image) else { continue }
            seen.append(time)
            signatures.append(signature)
        }
        let starts = SceneSelector.select(times: seen, signatures: signatures, duration: duration.seconds)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameEdge, height: frameEdge)
        generator.requestedTimeToleranceBefore = sceneTolerance
        generator.requestedTimeToleranceAfter = sceneTolerance
        var out: [Scene] = []
        for start in starts {
            try Task.checkCancellation()
            let time = CMTime(seconds: start, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image, let frame = rgb(image) else { continue }
            out.append(Scene(milliseconds: Int64((start * 1000).rounded()), frame: frame))
        }
        return out
    }

    /// The picture as 16 × 12 grey levels (what `SceneSelector` compares).
    static func grey(_ image: CGImage) -> [UInt8]? {
        let (w, h) = signatureSize
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Pixels as red, green, blue bytes (no alpha), by drawing into a known layout.
    static func rgb(_ image: CGImage) -> Frame? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            bytes[i * 3] = rgba[i * 4]
            bytes[i * 3 + 1] = rgba[i * 4 + 1]
            bytes[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return Frame(bytes: bytes, width: width, height: height)
    }
}
