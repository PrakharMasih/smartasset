// Perceptual hashes (plan A2): two 64-bit fingerprints of how a picture looks, not of its bytes.
//
//  * dHash ("difference hash"): shrink to 9 x 8 grey, then one bit per pair of neighbours: is the left one brighter?
//    Survives resizing and re-compression; follows edges.
//  * pHash ("DCT hash"): shrink to 32 x 32 grey, take the 8 x 8 lowest-frequency cosine coefficients without the
//    average brightness, one bit per coefficient: is it above the median? Survives resizing, re-compression, mild
//    colour and brightness changes.
//
// Two pictures that look alike differ in few bits of both. The Rust side compares them (sa-dedupe); this file only
// describes a picture. A plain picture (solid colour, black frame) has nothing to describe and returns nil.
import CoreBridge
import CoreGraphics
import Foundation

public enum Perceptual {
    /// Pictures whose brightness hardly varies at all (standard deviation of the 32 x 32 grey values).
    static let flatThreshold = 2.5
    /// The dHash grid: one more column than the 8 comparisons per row.
    private static let diffColumns = 8 + 1
    private static let diffRows = 8
    /// The pHash grid, and how many low frequencies of it are kept in each direction.
    private static let dctSize = 32

    /// Hashes of one picture, or nil if it is too plain to describe.
    public static func hash(of image: CGImage) -> PerceptualHashDto? {
        guard let small = grayPixels(of: image, width: dctSize, height: dctSize), standardDeviation(small) >= flatThreshold,
              let wide = grayPixels(of: image, width: diffColumns, height: diffRows) else { return nil }
        return PerceptualHashDto(dhash: differenceHash(wide), phash: dctHash(small))
    }

    /// Number of differing bits between two hashes, for tests and diagnostics.
    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    // MARK: - Pixels

    /// The picture as 8-bit grey, scaled to exactly `width` x `height` (aspect ratio is ignored on purpose, so a
    /// crop of the same width and a resize give the same grid). Transparency is flattened onto white.
    static func grayPixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    static func standardDeviation(_ pixels: [UInt8]) -> Double {
        guard !pixels.isEmpty else { return 0 }
        let n = Double(pixels.count)
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / n
        let variance = pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
        return variance.squareRoot()
    }

    // MARK: - dHash

    /// Bit `y * 8 + x` is set when pixel (x, y) is brighter than pixel (x + 1, y) on a 9 x 8 grid.
    static func differenceHash(_ pixels: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 where pixels[y * 9 + x] > pixels[y * 9 + x + 1] {
                hash |= 1 << UInt64(y * 8 + x)
            }
        }
        return hash
    }

    // MARK: - pHash

    /// cosine[k][n] = cos((2n + 1) k pi / 64): the DCT-II basis for 32 samples.
    private static let cosine: [[Double]] = (0..<8).map { k in
        (0..<32).map { n in cos(Double(2 * n + 1) * Double(k) * Double.pi / 64) }
    }

    /// Bit `i` (0...62) is set when the i-th low-frequency coefficient, in row order and without the average
    /// brightness, is above the median of the 63. Bit 63 is always 0.
    static func dctHash(_ pixels: [UInt8]) -> UInt64 {
        // Rows first: for each of the 8 vertical frequencies, the weighted sum down every column.
        var columns = [[Double]](repeating: [Double](repeating: 0, count: 32), count: 8)
        for v in 0..<8 {
            for x in 0..<32 {
                var sum = 0.0
                for y in 0..<32 { sum += Double(pixels[y * 32 + x]) * cosine[v][y] }
                columns[v][x] = sum
            }
        }
        var coefficients: [Double] = []
        coefficients.reserveCapacity(63)
        for v in 0..<8 {
            for u in 0..<8 where !(u == 0 && v == 0) {
                var sum = 0.0
                for x in 0..<32 { sum += columns[v][x] * cosine[u][x] }
                coefficients.append(sum)
            }
        }
        let median = coefficients.sorted()[31]
        var hash: UInt64 = 0
        for (i, c) in coefficients.enumerated() where c > median { hash |= 1 << UInt64(i) }
        return hash
    }
}
