// Hover-scrub (plan V2): a video's filmstrip is made once, kept on disk, and sliced into frames in memory.
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class FilmstripStore {
    static let shared = FilmstripStore()
    nonisolated static let frameCount = 16

    private let cache = NSCache<NSString, FrameBox>()
    private var generating: Set<String> = []
    private var waiters: [String: [() -> Void]] = [:]

    /// Decoded frames, handed from the worker thread to the main actor once and never changed.
    nonisolated final class FrameBox: @unchecked Sendable {
        let frames: [CGImage]
        nonisolated init(_ frames: [CGImage]) { self.frames = frames }
    }

    init() { cache.countLimit = 48 }

    /// The frames if they are ready; otherwise starts making them and calls `ready` when they are.
    func frames(id: Int64, rev: Int64, video: URL?, stripPath: String, ready: @escaping () -> Void) -> [CGImage]? {
        let key = "\(id)_\(rev)" as NSString
        if let box = cache.object(forKey: key) { return box.frames }
        guard let video else { return nil }
        waiters[key as String, default: []].append(ready)
        let name = key as String
        guard generating.insert(name).inserted else { return nil }
        Task { [self] in
            let box = await Task.detached(priority: .utility) { () -> FrameBox? in
                await Self.loadOrMake(video: video, stripPath: stripPath).map { FrameBox($0) }
            }.value
            generating.remove(name)
            if let box { cache.setObject(box, forKey: key) }
            let callbacks = waiters.removeValue(forKey: name) ?? []
            if box != nil { for callback in callbacks { callback() } }
        }
        return nil
    }

    nonisolated private static func loadOrMake(video: URL, stripPath: String) async -> [CGImage]? {
        if let strip = sliceExisting(stripPath) { return strip }
        guard let frames = await generate(video: video), !frames.isEmpty else { return nil }
        try? write(frames, to: stripPath)
        return frames
    }

    nonisolated private static func sliceExisting(_ path: String) -> [CGImage]? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width / frameCount
        guard width > 0 else { return nil }
        return (0..<frameCount).compactMap { image.cropping(to: CGRect(x: $0 * width, y: 0, width: width, height: image.height)) }
    }

    nonisolated private static func generate(video: URL) async -> [CGImage]? {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let duration = ((try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }) ?? 0
        guard duration.isFinite, duration > 0 else { return nil }
        var frames: [CGImage] = []
        var width = 0, height = 0
        for i in 0..<frameCount {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(frameCount), preferredTimescale: 600)
            guard var image = try? await generator.image(at: t).image else { continue }
            if width == 0 { width = image.width; height = image.height }
            // Every slice of the strip has the same size.
            if image.width != width || image.height != height, let resized = resize(image, width: width, height: height) { image = resized }
            frames.append(image)
        }
        // A short or damaged clip may yield fewer frames: repeat the last so the strip stays regular.
        while !frames.isEmpty, frames.count < frameCount { frames.append(frames[frames.count - 1]) }
        return frames
    }

    nonisolated private static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    nonisolated private static func write(_ frames: [CGImage], to path: String) throws {
        guard let first = frames.first,
              let ctx = CGContext(data: nil, width: first.width * frames.count, height: first.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        for (i, frame) in frames.enumerated() { ctx.draw(frame, in: CGRect(x: i * first.width, y: 0, width: first.width, height: first.height)) }
        guard let strip = ctx.makeImage() else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = path + ".tmp"
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: temp) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, strip, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        rename(temp, path)
    }
}
