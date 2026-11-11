// Writing thumbnails: JPEG, atomically, flattened so transparency never turns black.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Thumbnail {
    /// Quality that keeps a 512 px grid thumbnail around 20–40 KB.
    static let jpegQuality = 0.78

    /// Writes `image` as JPEG to `path` via a temporary file, so a half-written thumbnail is never visible.
    static func writeJPEG(_ image: CGImage, to path: String) throws {
        let flat = flattened(image)
        let temporary = path + ".tmp"
        let url = URL(fileURLWithPath: temporary)
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaFailure.thumbnail("cannot create the thumbnail file")
        }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw MediaFailure.thumbnail("cannot encode the thumbnail")
        }
        // rename(2) replaces an existing file atomically.
        if rename(temporary, path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: url)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    /// JPEG has no alpha. Draw transparent images over a neutral light gray instead of letting them go black.
    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.setFillColor(CGColor(srgbRed: 0.92, green: 0.92, blue: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Decodes the dimensions of a finished thumbnail file (used by tests and sanity checks).
    static func dimensions(ofFileAt path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}
