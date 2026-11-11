// Describing one picture or video for duplicate matching (plan A2). Never throws: a failure is a result.
import AVFoundation
import CoreBridge
import CoreGraphics
import Foundation
import ImageIO

public enum PerceptualProcessor {
    /// Where, as fractions of the duration, a video is sampled. Must equal `VIDEO_SAMPLE_POINTS` in sa-providers, so
    /// two encodes of one video are compared frame against frame.
    static let videoSamplePoints: [Double] = [0.2, 0.5, 0.8]

    static func timeout(for kind: MediaKind) -> Duration {
        switch kind {
        case .video: .seconds(120)
        case .image, .audio: .seconds(45)
        }
    }

    public static func process(_ task: PerceptualTaskDto) async -> PerceptualOutcomeDto {
        do {
            switch task.kind {
            case .image: return .done(hashes: try image(task))
            case .video: return .done(hashes: try await video(task))
            case .audio: return .done(hashes: [])
            }
        } catch {
            let (errorClass, message) = ErrorClassifier.classify(error)
            return .failed(class: Task.isCancelled ? .transient : errorClass, message: message)
        }
    }

    /// Like `process`, but a decoder that hangs on a damaged file cannot stall the batch.
    public static func processWithTimeout(_ task: PerceptualTaskDto) async -> PerceptualOutcomeDto {
        let limit = timeout(for: task.kind)
        return await withCheckedContinuation { (continuation: CheckedContinuation<PerceptualOutcomeDto, Never>) in
            let once = OneShot(continuation)
            Task.detached(priority: .utility) { once.resume(with: await process(task)) }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: limit)
                once.resume(with: .failed(class: .transient, message: "Reading this file took too long."))
            }
        }
    }

    // MARK: - Pictures

    /// A picture is hashed from its grid thumbnail when there is one (small, already upright, already decoded
    /// once), and from the original otherwise. Either gives the same hash for the same picture.
    private static func image(_ task: PerceptualTaskDto) throws -> [PerceptualHashDto] {
        try autoreleasepool {
            let path = task.thumbPath ?? task.path
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options as CFDictionary),
                  CGImageSourceGetCount(source) > 0 else {
                throw MediaFailure.corrupt("This file is not a readable image.")
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                throw MediaFailure.corrupt("The image data is damaged.")
            }
            return Perceptual.hash(of: picture).map { [$0] } ?? []
        }
    }

    // MARK: - Videos

    private static func video(_ task: PerceptualTaskDto) async throws -> [PerceptualHashDto] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: task.path))
        guard try await asset.load(.isReadable) else { throw MediaFailure.corrupt("This file is not readable as media.") }
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return [] }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw MediaFailure.corrupt("This video has no length.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        // Exact frames, so two encodes of the same video are sampled at the same instants.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var hashes: [PerceptualHashDto] = []
        for fraction in videoSamplePoints {
            let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
            let frame: CGImage
            do {
                frame = try await generator.image(at: time).image
            } catch {
                // An odd keyframe layout: the nearest frame is as good for matching.
                generator.requestedTimeToleranceBefore = .positiveInfinity
                generator.requestedTimeToleranceAfter = .positiveInfinity
                frame = try await generator.image(at: time).image
            }
            // A black frame or a plain card cannot be matched; the whole video then goes unmatched.
            guard let hash = Perceptual.hash(of: frame) else { return [] }
            hashes.append(hash)
        }
        return hashes
    }
}

/// Resumes a continuation exactly once, whichever of two racers gets there first.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PerceptualOutcomeDto, Never>?

    init(_ continuation: CheckedContinuation<PerceptualOutcomeDto, Never>) { self.continuation = continuation }

    func resume(with value: PerceptualOutcomeDto) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
