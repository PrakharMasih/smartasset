// Thumbnails from disk, decoded off the main thread, cached under a memory cap (plan §8: memory < 500 MB).
import AppKit
import ImageIO

nonisolated final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue

    init() {
        queue = OperationQueue()
        queue.name = "thumbnail-decode"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    /// Decode size classes: small tiles do not need the full 512 px file.
    static func pixelBucket(forPoints points: CGFloat, scale: CGFloat) -> Int {
        let needed = points * scale
        return needed <= 128 ? 128 : needed <= 256 ? 256 : 512
    }

    private func key(_ id: Int64, _ rev: Int64, _ bucket: Int) -> NSString { "\(id)_\(rev)_\(bucket)" as NSString }

    func cached(id: Int64, rev: Int64, bucket: Int) -> NSImage? {
        cache.object(forKey: key(id, rev, bucket))
    }

    /// Loads a thumbnail file. The returned operation can be cancelled when a reused tile no longer needs it.
    @discardableResult
    func load(id: Int64, rev: Int64, path: String, bucket: Int, completion: @escaping @MainActor (NSImage?) -> Void) -> Operation {
        let cacheKey = key(id, rev, bucket) as String
        let op = BlockOperation()
        op.addExecutionBlock { [weak op, weak self] in
            guard let op, !op.isCancelled else { return }
            let image = Self.decode(path: path, maxPixel: bucket)
            if let image { self?.cache.setObject(image, forKey: cacheKey as NSString, cost: Int(image.size.width * image.size.height) * 4) }
            guard !op.isCancelled else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(image) } }
        }
        queue.addOperation(op)
        return op
    }

    nonisolated private static func decode(path: String, maxPixel: Int) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func removeAll() { cache.removeAllObjects() }
}
