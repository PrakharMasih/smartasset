// Sample media for snapshots and demos: APP_DEMO=1 with APP_DATA pointing into /tmp. Never runs against a real library.
import AppKit
import AVFoundation
import CoreGraphics
import DemoMedia
import Foundation
import UniformTypeIdentifiers

enum DemoLibrary {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["APP_DEMO"] == "1" }

    /// Photos in six shapes, a few clips and tones, and one damaged file, spread over three folders.
    static func make(at root: URL) async throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        var count = 0
        let shapes: [(Int, Int)] = [(1500, 1000), (1200, 900), (1600, 900), (1000, 1000), (960, 1200), (900, 1600)]
        let places = ["Iceland Trip", "Studio Shoot", "Street"]
        for (index, place) in places.enumerated() {
            let dir = root.appending(path: place)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<14 {
                let n = index * 14 + i
                let (w, h) = shapes[n % shapes.count]
                let hue = CGFloat((n * 37) % 100) / 100
                let image = bitmap(width: w, height: h, hue: hue, seed: n)
                let url = dir.appending(path: String(format: "%@_%04d.jpg", ["IMG", "DSC", "P"][index], 1000 + n))
                let date = String(format: "2024:%02d:%02d 1%d:%02d:00", 3 + index, 1 + (i * 2) % 27, i % 10, (i * 7) % 60)
                let props: [CFString: Any] = [
                    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date, kCGImagePropertyExifISOSpeedRatings: [100 * (1 + n % 8)],
                                                     kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifFocalLength: 35.0],
                    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Sony", kCGImagePropertyTIFFModel: "A7 IV"],
                ]
                try MediaFixtures.writeImage(image, to: url, type: .jpeg, properties: props)
                count += 1
            }
        }
        try MediaFixtures.writeImage(MediaFixtures.bitmap(width: 800, height: 500, alpha: true), to: root.appending(path: "Street/logo.png"), type: .png)
        try await MediaFixtures.video(at: root.appending(path: "Studio Shoot/interview-wide.mp4"), width: 1280, height: 720, seconds: 3, fps: 24)
        try await MediaFixtures.video(at: root.appending(path: "Iceland Trip/drone-clip.mp4"), width: 960, height: 540, seconds: 4, fps: 24)
        try await MediaFixtures.video(at: root.appending(path: "Street/reel-vertical.mp4"), width: 640, height: 360, seconds: 2, fps: 24, portrait: true)
        for (i, name) in ["Iceland Trip/waves.wav", "Studio Shoot/voiceover.wav", "Street/ambience.wav"].enumerated() {
            try MediaFixtures.wav(at: root.appending(path: name), seconds: 2 + Double(i))
        }
        try Data((0..<3000).map { UInt8($0 % 233) }).write(to: root.appending(path: "Street/corrupt-shot.jpg"))
        return count + 8 + (try await makeDuplicates(in: root))
    }

    /// Copies for the Duplicates page: exact copies in other folders under other names, and look-alikes that are
    /// resized or re-saved. Returns how many files it added.
    private static func makeDuplicates(in root: URL) async throws -> Int {
        let fm = FileManager.default
        func copy(_ from: String, _ to: String) throws {
            let target = root.appending(path: to)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: root.appending(path: from), to: target)
        }
        // Exact copies: a photo three times, a clip twice, a sound twice.
        try copy("Iceland Trip/IMG_1002.jpg", "Street/Backup/IMG_1002 copy.jpg")
        try copy("Iceland Trip/IMG_1002.jpg", "Studio Shoot/Exports/IMG_1002-final.jpg")
        try copy("Studio Shoot/interview-wide.mp4", "Street/Backup/interview-wide copy.mp4")
        try copy("Iceland Trip/waves.wav", "Studio Shoot/Exports/waves-old.wav")
        // Look-alikes: the same shot resized for the web, and re-saved small.
        let original = root.appending(path: "Studio Shoot/DSC_1020.jpg")
        for (name, edge, quality) in [("DSC_1020-web.jpg", 700, 0.6), ("DSC_1020-small.jpg", 320, 0.8)] {
            guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: edge,
                      kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
            let out = root.appending(path: "Studio Shoot/Exports/\(name)")
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MediaFixtures.writeImage(image, to: out, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
        }
        // A clip with real content (a slow push in on a photo), and the same clip again at a lower quality.
        var videos = 0
        let clip = root.appending(path: "Iceland Trip/push-in.mp4")
        try await MediaFixtures.zoomVideo(from: bitmap(width: 1600, height: 900, hue: 0.55, seed: 90), at: clip, width: 1280, height: 720, seconds: 3, fps: 24)
        videos += 1
        if let session = AVAssetExportSession(asset: AVURLAsset(url: clip), presetName: AVAssetExportPresetMediumQuality) {
            let out = root.appending(path: "Street/Backup/push-in-medium.mp4")
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? await session.export(to: out, as: .mp4)) != nil { videos += 1 }
        }
        return 4 + 2 + videos
    }

    /// A colorful picture: sky-to-ground gradient in one hue family, with a few shapes.
    private static func bitmap(width: Int, height: Int, hue: CGFloat, seed: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        func color(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor {
            NSColor(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1).cgColor
        }
        let gradient = CGGradient(colorsSpace: space, colors: [color(hue, 0.55, 0.95), color(hue + 0.12, 0.8, 0.45)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        var rng = SeededRandom(seed: UInt64(seed + 1))
        for _ in 0..<5 {
            ctx.setFillColor(color(hue + 0.3 * rng.next(), 0.5, 0.9).copy(alpha: 0.55)!)
            let size = CGFloat(min(width, height)) * (0.15 + 0.3 * rng.next())
            ctx.fillEllipse(in: CGRect(x: CGFloat(width) * rng.next() - size / 2, y: CGFloat(height) * rng.next() - size / 2, width: size, height: size))
        }
        ctx.setFillColor(color(hue, 0.3, 0.2).copy(alpha: 0.6)!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 6))
        return ctx.makeImage()!
    }

    struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 10_000) / 10_000
        }
    }
}
