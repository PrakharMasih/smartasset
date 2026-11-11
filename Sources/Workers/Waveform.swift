// Audio waveforms: peak envelopes for thumbnails now, and for the player later (plan V4).
import AVFoundation
import CoreGraphics
import Foundation

public enum Waveform {
    /// Files longer than this are sampled in windows instead of decoded end to end.
    static let fullDecodeLimit: Double = 30 * 60
    static let windowCount = 32
    static let windowSeconds: Double = 10
    /// AVAssetReader rejects anything below 8 kHz by raising an Objective-C exception, which Swift cannot catch.
    static let decodeRate: Double = 8_000

    /// Peak amplitude (0…1) in `buckets` equal slices of the file.
    public static func peaks(of url: URL, buckets: Int = 256) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, buckets > 0 else { return [] }
        var peaks = [Float](repeating: 0, count: buckets)
        if duration <= fullDecodeLimit {
            try read(asset: asset, track: track, from: 0, seconds: duration, into: &peaks, bucketRange: 0..<buckets)
        } else {
            // A three-hour recording is not worth decoding for a thumbnail: look at evenly spaced windows.
            let per = max(1, buckets / windowCount)
            for w in 0..<windowCount {
                let start = (duration - windowSeconds) * Double(w) / Double(windowCount - 1)
                let lo = min(buckets - 1, w * per)
                let hi = w == windowCount - 1 ? buckets : min(buckets, lo + per)
                try read(asset: asset, track: track, from: max(0, start), seconds: windowSeconds, into: &peaks, bucketRange: lo..<hi)
            }
        }
        return peaks
    }

    private static func read(asset: AVURLAsset, track: AVAssetTrack, from start: Double, seconds: Double,
                             into peaks: inout [Float], bucketRange: Range<Int>) throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: decodeRate,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaFailure.unsupported("This audio cannot be decoded.") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? MediaFailure.corrupt("This audio could not be read.")
        }
        let expected = max(1, Int(seconds * decodeRate))
        let bucketCount = bucketRange.count
        var index = 0
        var scratch = [Int16](repeating: 0, count: 8192)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Int16>.size
            if scratch.count < count { scratch = [Int16](repeating: 0, count: count) }
            scratch.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base) }
            }
            for i in 0..<count {
                let bucket = min(bucketCount - 1, index * bucketCount / expected)
                let value = Float(abs(Int(scratch[i]))) / 32768
                let slot = bucketRange.lowerBound + bucket
                if value > peaks[slot] { peaks[slot] = value }
                index += 1
            }
        }
        if reader.status == .failed { throw reader.error ?? MediaFailure.corrupt("This audio could not be read.") }
    }

    /// Draws a symmetric waveform on a dark panel.
    static func render(_ peaks: [Float], width: Int = 512, height: Int = 256) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let mid = CGFloat(height) / 2
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: mid)); context.addLine(to: CGPoint(x: CGFloat(width), y: mid)); context.strokePath()
        guard !peaks.isEmpty else { return context.makeImage() }
        // Normalise so quiet recordings still show a shape.
        let top = max(peaks.max() ?? 0, 0.05)
        context.setFillColor(CGColor(srgbRed: 0.45, green: 0.72, blue: 1.0, alpha: 1))
        let barWidth = CGFloat(width) / CGFloat(peaks.count)
        for (i, p) in peaks.enumerated() {
            let h = max(2, CGFloat(p / top) * (mid - 10))
            let x = CGFloat(i) * barWidth
            context.fill(CGRect(x: x, y: mid - h, width: max(1, barWidth - 1), height: h * 2))
        }
        return context.makeImage()
    }
}
