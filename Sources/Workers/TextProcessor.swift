// One file's worth of text reading (Phase 4, S4): the words macOS's Vision framework finds in a picture, or in three
// frames of a video. Only the words go back to Rust; no pixels cross the bridge. English first (plan §16).
import AVFoundation
import CoreBridge
import CoreGraphics
import Foundation
import ImageIO
import Vision

public enum TextProcessor {
    /// Names how text is read. Another value makes Rust read every file again (with that reader).
    public static let reader = "vision-accurate-en-v1"
    /// The longest edge a picture is decoded at. Small print on a slide or screenshot needs far more pixels than the
    /// 512 px grid thumbnail has; Vision gains little above this and takes longer.
    static let pictureEdge = 2048
    static let frameEdge: CGFloat = 1280
    /// Where, as fractions of the duration, a video is read (the instants the other workers use).
    static let videoSamplePoints: [Double] = [0.2, 0.5, 0.8]
    /// Lines Vision is less sure of than this are left out: they are mostly texture read as letters.
    static let minimumConfidence: Float = 0.4

    static func timeout(for kind: MediaKind) -> Duration {
        kind == .video ? .seconds(120) : .seconds(60)
    }

    public static func process(_ task: TextTaskDto) async -> TextOutcomeDto {
        do {
            switch task.kind {
            case .image:
                guard let image = picture(at: task.path) ?? task.thumbPath.flatMap(picture(at:)) else {
                    throw MediaFailure.unsupported("This picture could not be read for text.")
                }
                return .done(text: try lines(in: image).joined(separator: "\n"))
            case .video:
                var seen = Set<String>()
                var all: [String] = []
                for frame in try await frames(of: task) {
                    try Task.checkCancellation()
                    // A title that stays on screen is read once.
                    for line in try lines(in: frame) where seen.insert(line.lowercased()).inserted { all.append(line) }
                }
                return .done(text: all.joined(separator: "\n"))
            case .audio:
                return .done(text: "")
            }
        } catch is CancellationError {
            return .failed(class: .transient, message: "Stopped before it finished.")
        } catch let failure as MediaFailure {
            let (errorClass, message) = ErrorClassifier.classify(failure)
            return .failed(class: errorClass, message: message)
        } catch {
            let (errorClass, message) = ErrorClassifier.classify(error)
            return .failed(class: errorClass, message: message)
        }
    }

    /// Like `process`, but a decoder that hangs on a damaged file cannot stall the batch.
    public static func processWithTimeout(_ task: TextTaskDto) async -> TextOutcomeDto {
        let limit = timeout(for: task.kind)
        return await withTaskGroup(of: TextOutcomeDto.self) { group in
            group.addTask { await process(task) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .failed(class: .transient, message: "Reading this file took too long.")
            }
            let first = await group.next() ?? .failed(class: .transient, message: "No answer.")
            group.cancelAll()
            return first
        }
    }

    /// The lines of text Vision reads in `image`, top to bottom.
    static func lines(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= minimumConfidence else { return nil }
            let line = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
    }

    /// The picture at up to `pictureEdge` pixels, upright; nil if ImageIO cannot read it. A camera raw file's embedded
    /// preview is used when it is large enough.
    static func picture(at path: String) -> CGImage? {
        autoreleasepool {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, sourceOptions as CFDictionary),
                  CGImageSourceGetCount(source) > 0 else { return nil }
            func thumbnail(fromImage: Bool) -> CGImage? {
                var options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pictureEdge,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                options[fromImage ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            // A JPEG's embedded thumbnail is tiny, so an embedded image counts only when it is nearly full size.
            if let embedded = thumbnail(fromImage: false), max(embedded.width, embedded.height) >= pictureEdge * 3 / 4 {
                return embedded
            }
            return thumbnail(fromImage: true)
        }
    }

    private static func frames(of task: TextTaskDto) async throws -> [CGImage] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: task.path))
        guard try await asset.load(.isReadable) else { throw MediaFailure.corrupt("This file is not readable as media.") }
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return [] }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw MediaFailure.corrupt("This video has no length.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameEdge, height: frameEdge)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var out: [CGImage] = []
        for fraction in videoSamplePoints {
            let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image { out.append(image) }
        }
        return out
    }
}
