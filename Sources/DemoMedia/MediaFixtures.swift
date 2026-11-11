// Real media files made on the fly: the decoders are tested on them, and snapshot mode shows them.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Failure: Error, CustomStringConvertible {
    case message(String)
    public var description: String { if case .message(let m) = self { m } else { "" } }
}

public enum MediaFixtures {
    /// A bitmap with a gradient and shapes, so thumbnails have something to show.
    public static func bitmap(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        if alpha { ctx.clear(CGRect(x: 0, y: 0, width: width, height: height)) } else {
            let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1),
                                                                  CGColor(srgbRed: 0.9, green: 0.5, blue: 0.1, alpha: 1)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    public static func writeImage(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure.message("cannot create \(type.identifier) destination")
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.message("cannot write \(url.lastPathComponent)") }
    }

    /// A camera-style JPEG: rotated, with exposure data, lens, camera and a GPS fix in San Francisco.
    public static func cameraJPEG(at url: URL, width: Int = 4000, height: Int = 3000, orientation: Int = 6) throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:03:05 14:22:01",
                "OffsetTimeOriginal" as CFString: "+02:00",
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFocalLength: 35.0,
                kCGImagePropertyExifLensModel: "RF 35mm F1.8",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W",
            ],
        ]
        try writeImage(bitmap(width: width, height: height), to: url, type: .jpeg, properties: properties)
    }

    /// An H.264 clip. `portrait` stores a landscape frame with a 90° rotation, like a phone held upright.
    public static func video(at url: URL, width: Int = 640, height: Int = 360, seconds: Double = 2, fps: Int = 24,
                      portrait: Bool = false, codec: AVVideoCodecType = .h264, fileType: AVFileType = .mp4) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        if portrait { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.message("cannot start writing video") }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw Failure.message("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        row[x * 4] = UInt8((x * 255) / max(1, width))
                        row[x * 4 + 1] = UInt8((y * 255) / max(1, height))
                        row[x * 4 + 2] = UInt8((frame * 255) / max(1, frames))
                        row[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.message("video writer failed") }
    }

    /// An H.264 clip made of solid-colour scenes, each lasting `secondsPerScene`: a video whose picture changes at known
    /// instants, for checking where scenes are found.
    public static func sceneVideo(at url: URL, colors: [(UInt8, UInt8, UInt8)], secondsPerScene: Double = 3, width: Int = 320,
                                  height: Int = 180, fps: Int = 10) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.message("cannot start writing video") }
        writer.startSession(atSourceTime: .zero)
        let perScene = Int(secondsPerScene * Double(fps))
        for frame in 0..<(perScene * colors.count) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw Failure.message("no pixel buffer") }
            let (r, g, b) = colors[frame / perScene]
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { row[x * 4] = b; row[x * 4 + 1] = g; row[x * 4 + 2] = r; row[x * 4 + 3] = 255 }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.message("video writer failed") }
    }

    /// A mono WAV with a fading sine tone.
    public static func wav(at url: URL, seconds: Double = 2, sampleRate: Double = 44_100) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let fade = Float(1.0 - Double(i) / Double(frames))
            samples[i] = 0.8 * fade * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
        try file.write(from: buffer)
    }

    /// Pixel brightness (0…1) at a position of a decoded image file.
    public static func brightness(ofImageAt path: String, x: Int, y: Int) -> Double? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let row = data.advanced(by: (image.height - 1 - y) * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self)
        return (Double(row[x * 4]) + Double(row[x * 4 + 1]) + Double(row[x * 4 + 2])) / (3 * 255)
    }
}

public extension MediaFixtures {
    /// A clip that zooms slowly into a photo, so every video has its own real content and frames that change over time.
    static func zoomVideo(from photo: CGImage, at url: URL, width: Int, height: Int, seconds: Double, fps: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.message("cannot start writing") }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw Failure.message("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer),
               let c = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                c.interpolationQuality = .medium
                let zoom = 1.0 + 0.25 * Double(frame) / Double(max(1, frames - 1))
                let w = Double(width) * zoom, h = Double(height) * zoom
                c.draw(photo, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure.message("writing failed") }
    }
}
