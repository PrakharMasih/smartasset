// Altered copies of a photograph (resized, re-encoded, brighter, cropped …): the near-duplicate labeled set of Phase 2
// (A2), shared by the unit tests (perceptual hashes) and the in-app self-test (confirmation by meaning).
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PhotoVariants {
    /// One altered copy: what was done, the picture, and the JPEG quality to write it with.
    public struct Variant: Sendable {
        public let name: String
        public let image: CGImage
        public let quality: Double
    }

    /// The labeled set's changes, in order. Every one is a copy of the same shot; "crop 20%" is the one perceptual hashes
    /// are known to miss.
    public static func variants(of original: CGImage) throws -> [Variant] {
        [
            Variant(name: "resize 50%", image: try scaled(original, width: original.width / 2), quality: 0.85),
            Variant(name: "resize 25%", image: try scaled(original, width: original.width / 4), quality: 0.85),
            Variant(name: "re-encode q40", image: original, quality: 0.4),
            Variant(name: "re-encode q10", image: original, quality: 0.1),
            Variant(name: "brighter", image: try adjusted(original, brightness: 0.12, contrast: 1, saturation: 1), quality: 0.85),
            Variant(name: "less contrast", image: try adjusted(original, brightness: 0, contrast: 0.8, saturation: 0.85), quality: 0.85),
            Variant(name: "grayscale", image: try adjusted(original, brightness: 0, contrast: 1, saturation: 0), quality: 0.85),
            Variant(name: "crop 5%", image: try cropped(original, keeping: 0.95), quality: 0.85),
            Variant(name: "crop 10%", image: try cropped(original, keeping: 0.90), quality: 0.85),
            Variant(name: "crop 20%", image: try cropped(original, keeping: 0.80), quality: 0.85),
        ]
    }

    public static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.message("cannot create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.message("cannot write \(url.lastPathComponent)") }
    }

    public static func context(width: Int, height: Int) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.message("no bitmap context") }
        c.interpolationQuality = .high
        return c
    }

    public static func scaled(_ image: CGImage, width: Int) throws -> CGImage {
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        let c = try context(width: width, height: height)
        c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = c.makeImage() else { throw Failure.message("scaling failed") }
        return out
    }

    /// Keeps the centre `fraction` of each side.
    public static func cropped(_ image: CGImage, keeping fraction: Double) throws -> CGImage {
        let w = Int(Double(image.width) * fraction), h = Int(Double(image.height) * fraction)
        let rect = CGRect(x: (image.width - w) / 2, y: (image.height - h) / 2, width: w, height: h)
        guard let out = image.cropping(to: rect) else { throw Failure.message("crop failed") }
        return out
    }

    public static func adjusted(_ image: CGImage, brightness: Double, contrast: Double, saturation: Double) throws -> CGImage {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorControls") else { throw Failure.message("no colour filter") }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: input.extent) else {
            throw Failure.message("filter failed")
        }
        return cg
    }
}
