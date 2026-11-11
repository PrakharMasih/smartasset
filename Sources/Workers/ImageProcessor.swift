// Images: metadata and a grid thumbnail through ImageIO (JPEG, PNG, HEIC, WebP, GIF, TIFF, camera RAW).
import CoreBridge
import CoreGraphics
import Foundation
import ImageIO
import SmartAssetKit

enum ImageProcessor {
    /// Camera RAW: use the embedded preview when it is big enough; decoding the raw sensor data is far slower.
    private static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw",
        "x3f", "3fr", "erf", "kdc", "mrw", "mef", "mos", "rwl", "iiq", "fff",
    ]

    static func process(_ task: MediaTaskDto) throws -> (ProbeDto, Bool) {
        try autoreleasepool {
            let url = URL(fileURLWithPath: task.path)
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            let isRaw = rawExtensions.contains(task.ext.lowercased())
            // Camera RAW support is per camera model, and macOS lacks older ones: say so instead of calling the file damaged.
            let rawUnsupported = MediaFailure.unsupported("macOS can’t read this camera’s RAW format (the camera may be too old or too new for this macOS), or the file is damaged.")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                throw isRaw ? rawUnsupported : MediaFailure.corrupt("This file is not a readable image.")
            }
            guard CGImageSourceGetType(source) != nil else {
                throw isRaw ? rawUnsupported : MediaFailure.unsupported("macOS cannot read this image format.")
            }
            guard CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) != .statusInvalidData else {
                throw isRaw ? rawUnsupported : MediaFailure.corrupt("The image data is damaged.")
            }
            let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            var probe = ProbeDto.empty
            fill(&probe, from: properties)

            let image: CGImage
            do { image = try makeThumbnail(source: source, maxEdge: Int(task.maxEdge), raw: isRaw) } catch { throw isRaw ? rawUnsupported : error }
            try Thumbnail.writeJPEG(image, to: task.thumbPath)
            if probe.width == nil || probe.height == nil {
                // Fall back to the thumbnail's shape when the container reports no size.
                probe.width = UInt32(image.width)
                probe.height = UInt32(image.height)
            }
            return (probe, true)
        }
    }

    private static func makeThumbnail(source: CGImageSource, maxEdge: Int, raw: Bool) throws -> CGImage {
        func attempt(preferEmbedded: Bool) -> CGImage? {
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            options[preferEmbedded ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways] = true
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        if raw, let preview = attempt(preferEmbedded: true), max(preview.width, preview.height) >= maxEdge / 2 {
            return preview
        }
        guard let image = attempt(preferEmbedded: false) else {
            throw MediaFailure.corrupt("The image could not be decoded.")
        }
        return image
    }

    private static func fill(_ probe: inout ProbeDto, from props: [CFString: Any]) {
        let rawWidth = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let rawHeight = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        // Orientations 5–8 are rotated a quarter turn: what people see is the other way round.
        let swapped = (5...8).contains(orientation)
        if rawWidth > 0, rawHeight > 0 {
            probe.width = UInt32(swapped ? rawHeight : rawWidth)
            probe.height = UInt32(swapped ? rawWidth : rawHeight)
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String {
            probe.captureAt = ExifFormat.captureDate(
                original,
                offset: exif["OffsetTimeOriginal" as CFString] as? String ?? exif["OffsetTimeDigitized" as CFString] as? String,
                subsecond: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)
        }
        probe.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        probe.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        probe.lens = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty

        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            probe.gpsLat = ExifFormat.signedCoordinate(lat, reference: gps[kCGImagePropertyGPSLatitudeRef] as? String)
            probe.gpsLon = ExifFormat.signedCoordinate(lon, reference: gps[kCGImagePropertyGPSLongitudeRef] as? String)
        }

        var details: [String: String] = [:]
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { details["ISO"] = String(iso) }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { details["Aperture"] = ExifFormat.aperture(f) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double { details["Shutter speed"] = ExifFormat.shutter(t) }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { details["Focal length"] = ExifFormat.focalLength(fl) }
        if let software = (tiff[kCGImagePropertyTIFFSoftware] as? String)?.nonEmpty { details["Software"] = software }
        if let profile = (props[kCGImagePropertyProfileName] as? String)?.nonEmpty { details["Color profile"] = profile }
        if let model = (props[kCGImagePropertyColorModel] as? String)?.nonEmpty { details["Color model"] = model }
        if let depth = props[kCGImagePropertyDepth] as? Int { details["Bit depth"] = String(depth) }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 { details["Resolution"] = "\(Int(dpi.rounded())) dpi" }
        if !details.isEmpty, let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]) {
            probe.exifJson = String(decoding: data, as: UTF8.self)
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
