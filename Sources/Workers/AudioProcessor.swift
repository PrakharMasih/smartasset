// Audio: metadata and a waveform thumbnail (WAV, AIFF, MP3, AAC/M4A, FLAC).
import AVFoundation
import CoreBridge
import Foundation
import SmartAssetKit

enum AudioProcessor {
    static func process(_ task: MediaTaskDto) async throws -> (ProbeDto, Bool) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: task.path))
        guard try await asset.load(.isReadable) else { throw MediaFailure.corrupt("This file is not readable as audio.") }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaFailure.unsupported("macOS found no audio it can play in this file.")
        }
        var probe = ProbeDto.empty
        let duration = try await asset.load(.duration)
        if duration.isNumeric, duration.seconds.isFinite { probe.durationMs = Int64((duration.seconds * 1000).rounded()) }
        let rate = try await track.load(.estimatedDataRate)
        if rate > 0 { probe.bitrate = Int64(rate) }
        if let description = try await track.load(.formatDescriptions).first {
            probe.codec = MediaNames.codec(fourCC: MediaNames.fourCCString(CMFormatDescriptionGetMediaSubType(description)))
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                probe.sampleRate = Int64(basic.mSampleRate)
                probe.channels = Int64(basic.mChannelsPerFrame)
            }
        }
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) {
            probe.captureAt = Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        let peaks = try await Waveform.peaks(of: URL(fileURLWithPath: task.path), buckets: 128)
        guard let image = Waveform.render(peaks) else { throw MediaFailure.thumbnail("cannot draw the waveform") }
        try Thumbnail.writeJPEG(image, to: task.thumbPath)
        return (probe, true)
    }
}
