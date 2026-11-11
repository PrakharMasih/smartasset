// Video: metadata and a poster frame through AVFoundation (MOV, MP4, M4V; H.264, HEVC, ProRes).
import AVFoundation
import CoreBridge
import CoreGraphics
import Foundation
import SmartAssetKit

enum VideoProcessor {
    static func process(_ task: MediaTaskDto) async throws -> (ProbeDto, Bool) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: task.path))
        guard try await asset.load(.isReadable) else { throw MediaFailure.corrupt("This file is not readable as media.") }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            // An .mp4 that holds only sound is audio.
            if try await !asset.loadTracks(withMediaType: .audio).isEmpty { return try await AudioProcessor.process(task) }
            throw MediaFailure.corrupt("No video or audio was found in this file.")
        }
        guard try await asset.load(.isPlayable) else {
            throw MediaFailure.unsupported("macOS cannot decode this video's format.")
        }

        var probe = ProbeDto.empty
        let duration = try await asset.load(.duration)
        if duration.isNumeric, duration.seconds.isFinite { probe.durationMs = Int64((duration.seconds * 1000).rounded()) }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let shown = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = Int(abs(shown.width).rounded()), height = Int(abs(shown.height).rounded())
        if width > 0, height > 0 {
            probe.width = UInt32(width)
            probe.height = UInt32(height)
        }
        let fps = try await track.load(.nominalFrameRate)
        if fps > 0 { probe.fps = Double(fps) }
        let rate = try await track.load(.estimatedDataRate)
        if rate > 0 { probe.bitrate = Int64(rate) }
        if let description = try await track.load(.formatDescriptions).first {
            probe.codec = MediaNames.codec(fourCC: MediaNames.fourCCString(CMFormatDescriptionGetMediaSubType(description)))
        }
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let description = try await audio.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            probe.sampleRate = Int64(basic.mSampleRate)
            probe.channels = Int64(basic.mChannelsPerFrame)
        }
        await readMetadata(asset, into: &probe)

        // Poster frame: ten percent in (at most five seconds), where fades from black are usually over.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Int(task.maxEdge), height: Int(task.maxEdge))
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let seconds = duration.isNumeric && duration.seconds.isFinite ? min(duration.seconds * 0.1, 5) : 0
        let image: CGImage
        do {
            image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        } catch {
            // A damaged tail or an odd keyframe layout: the very first frame is the last resort.
            image = try await generator.image(at: .zero).image
        }
        try Thumbnail.writeJPEG(image, to: task.thumbPath)
        return (probe, true)
    }

    /// Creation date, camera make/model and location from QuickTime metadata (iPhones, drones, cameras).
    private static func readMetadata(_ asset: AVURLAsset, into probe: inout ProbeDto) async {
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) {
            probe.captureAt = Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        guard let items = try? await asset.load(.metadata) else { return }
        for item in items {
            switch item.identifier {
            case .quickTimeMetadataLocationISO6709:
                if let text = try? await item.load(.stringValue), let coordinate = Iso6709.parse(text) {
                    probe.gpsLat = coordinate.latitude
                    probe.gpsLon = coordinate.longitude
                }
            case .quickTimeMetadataMake:
                probe.cameraMake = (try? await item.load(.stringValue))?.nonEmpty
            case .quickTimeMetadataModel:
                probe.cameraModel = (try? await item.load(.stringValue))?.nonEmpty
            default:
                break
            }
        }
    }
}
