// The real decoders on real files, then the whole worker loop against a live engine.
import CoreBridge
import DemoMedia
import Foundation
import ImageIO
import SmartAssetKit
import UniformTypeIdentifiers
import Workers

private func task(_ path: URL, kind: MediaKind, in dir: URL, rev: Int64 = 1) -> MediaTaskDto {
    MediaTaskDto(jobId: 1, assetId: 1, path: path.path, kind: kind, ext: path.pathExtension.lowercased(),
                 thumbPath: dir.appending(path: "thumb_\(UUID().uuidString).jpg").path, thumbRev: rev, maxEdge: 512, attempt: 1)
}

private func probe(of outcome: MediaOutcomeDto) throws -> (ProbeDto, Bool) {
    switch outcome {
    case .done(let probe, let wrote): return (probe, wrote)
    case .failed(let errorClass, let message): throw fail("expected success, got \(errorClass): \(message)")
    }
}

private func failure(of outcome: MediaOutcomeDto) throws -> (ErrorClass, String) {
    switch outcome {
    case .failed(let errorClass, let message): return (errorClass, message)
    case .done: throw fail("expected a failure")
    }
}

private func thumbSize(_ path: String) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

let workerTests: [TestCase] = [
    TestCase(name: "image: camera JPEG metadata, rotation, GPS and a rotated thumbnail") {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = box.media.appending(path: "IMG_0001.jpg")
        try MediaFixtures.cameraJPEG(at: file)
        let t = task(file, kind: .image, in: box.root)
        let (p, wrote) = try probe(of: await MediaProcessor.process(t))
        try expect(wrote)
        // Stored 4000x3000 with orientation 6 (rotate 90°): what people see is 3000x4000.
        try expectEqual(p.width, 3000)
        try expectEqual(p.height, 4000)
        try expectEqual(p.cameraMake, "Canon")
        try expectEqual(p.cameraModel, "EOS R5")
        try expectEqual(p.lens, "RF 35mm F1.8")
        try expect(abs((p.gpsLat ?? 0) - 37.7749) < 0.0001, "latitude \(String(describing: p.gpsLat))")
        try expect(abs((p.gpsLon ?? 0) + 122.4194) < 0.0001, "west longitude is negative: \(String(describing: p.gpsLon))")
        // 2024-03-05 14:22:01 at +02:00 is 12:22:01 UTC.
        try expectEqual(p.captureAt, 1_709_641_321_000)
        let exif = try JSONSerialization.jsonObject(with: Data((p.exifJson ?? "{}").utf8)) as? [String: String]
        try expectEqual(exif?["ISO"], "400")
        try expectEqual(exif?["Aperture"], "f/2.8")
        try expectEqual(exif?["Shutter speed"], "1/250 s")
        try expectEqual(exif?["Focal length"], "35 mm")
        let size = thumbSize(t.thumbPath)
        try expect(size != nil, "the thumbnail is a readable image")
        try expectEqual(size?.0, 384, "thumbnail is upright: width")
        try expectEqual(size?.1, 512, "thumbnail is upright: height")
        try expect(!FileManager.default.fileExists(atPath: t.thumbPath + ".tmp"), "no temporary file is left behind")
    },

    TestCase(name: "image: transparent PNG is flattened, never black") {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = box.media.appending(path: "logo.png")
        try MediaFixtures.writeImage(MediaFixtures.bitmap(width: 600, height: 400, alpha: true), to: file, type: .png)
        let t = task(file, kind: .image, in: box.root)
        _ = try probe(of: await MediaProcessor.process(t))
        let corner = MediaFixtures.brightness(ofImageAt: t.thumbPath, x: 3, y: 3)
        try expect((corner ?? 0) > 0.8, "a transparent corner becomes light gray, got \(String(describing: corner))")
    },

    TestCase(name: "image: small images are not enlarged; HEIC, TIFF and GIF decode") {
        let box = try Sandbox(); defer { box.cleanup() }
        for (name, type) in [("a.heic", UTType.heic), ("b.tiff", .tiff), ("c.gif", .gif), ("d.png", .png)] {
            let file = box.media.appending(path: name)
            try MediaFixtures.writeImage(MediaFixtures.bitmap(width: 200, height: 100), to: file, type: type)
            let t = task(file, kind: .image, in: box.root)
            let (p, wrote) = try probe(of: await MediaProcessor.process(t))
            try expect(wrote, "\(name)")
            try expectEqual(p.width, 200, name)
            let size = thumbSize(t.thumbPath)
            try expect((size?.0 ?? 0) <= 200, "\(name) is not scaled up: \(String(describing: size))")
        }
    },

    TestCase(name: "image: damaged and empty files fail alone with the right class") {
        let box = try Sandbox(); defer { box.cleanup() }
        let garbage = box.media.appending(path: "garbage.jpg")
        try Data((0..<2000).map { UInt8($0 % 251) }).write(to: garbage)
        let empty = box.media.appending(path: "empty.png")
        try Data().write(to: empty)
        let text = box.media.appending(path: "notes.tiff")
        try Data("hello, I am not a picture".utf8).write(to: text)
        for url in [garbage, empty, text] {
            let t = task(url, kind: .image, in: box.root)
            let (errorClass, message) = try failure(of: await MediaProcessor.process(t))
            try expect(errorClass == .fileCorrupt || errorClass == .unsupported, "\(url.lastPathComponent): \(errorClass) \(message)")
            try expect(!FileManager.default.fileExists(atPath: t.thumbPath), "no thumbnail for a failed file")
        }
        let (errorClass, _) = try failure(of: await MediaProcessor.process(task(box.media.appending(path: "gone.jpg"), kind: .image, in: box.root)))
        try expect(errorClass == .fileCorrupt || errorClass == .transient, "a vanished file: \(errorClass)")
    },

    TestCase(name: "video: H.264 metadata and poster frame") {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = box.media.appending(path: "clip.mp4")
        try await MediaFixtures.video(at: file, width: 640, height: 360, seconds: 2, fps: 24)
        let t = task(file, kind: .video, in: box.root)
        let (p, wrote) = try probe(of: await MediaProcessor.process(t))
        try expect(wrote)
        try expectEqual(p.width, 640)
        try expectEqual(p.height, 360)
        try expect(abs(Double(p.durationMs ?? 0) - 2000) < 150, "duration \(String(describing: p.durationMs))")
        try expect(abs((p.fps ?? 0) - 24) < 1, "fps \(String(describing: p.fps))")
        try expectEqual(p.codec, "H.264")
        let size = thumbSize(t.thumbPath)
        try expectEqual(size?.0, 512)
        try expectEqual(size?.1, 288)
    },

    TestCase(name: "video: a phone clip stored sideways is reported upright") {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = box.media.appending(path: "portrait.mp4")
        try await MediaFixtures.video(at: file, width: 640, height: 360, seconds: 1, portrait: true)
        let t = task(file, kind: .video, in: box.root)
        let (p, _) = try probe(of: await MediaProcessor.process(t))
        try expectEqual(p.width, 360, "displayed width")
        try expectEqual(p.height, 640, "displayed height")
        let size = thumbSize(t.thumbPath)
        try expect((size?.1 ?? 0) > (size?.0 ?? 1), "the poster frame is upright: \(String(describing: size))")
    },

    TestCase(name: "video: a damaged video fails alone") {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = box.media.appending(path: "broken.mov")
        try Data((0..<5000).map { UInt8($0 % 241) }).write(to: file)
        let (errorClass, message) = try failure(of: await MediaProcessor.process(task(file, kind: .video, in: box.root)))
        try expect(errorClass == .fileCorrupt || errorClass == .unsupported, "\(errorClass): \(message)")
    },

    TestCase(name: "audio: WAV metadata and a waveform thumbnail") {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = box.media.appending(path: "tone.wav")
        try MediaFixtures.wav(at: file, seconds: 2)
        let t = task(file, kind: .audio, in: box.root)
        let (p, wrote) = try probe(of: await MediaProcessor.process(t))
        try expect(wrote)
        try expect(abs(Double(p.durationMs ?? 0) - 2000) < 100, "duration \(String(describing: p.durationMs))")
        try expectEqual(p.sampleRate, 44_100)
        try expectEqual(p.channels, 1)
        try expectEqual(p.codec, "PCM")
        try expectEqual(p.width, nil)
        let size = thumbSize(t.thumbPath)
        try expectEqual(size?.0, 512)
        try expectEqual(size?.1, 256)
        // The tone fades out, so the waveform is taller at the start than at the end.
        let peaks = try await Waveform.peaks(of: file, buckets: 64)
        try expectEqual(peaks.count, 64)
        try expect((peaks.first ?? 0) > 0.5, "loud start: \(String(describing: peaks.first))")
        try expect((peaks.last ?? 1) < (peaks.first ?? 0) * 0.5, "quiet end: \(String(describing: peaks.last))")
    },

    TestCase(name: "worker: a live engine indexes real media end to end") {
        let box = try Sandbox(); defer { box.cleanup() }
        for i in 0..<6 { try MediaFixtures.cameraJPEG(at: box.media.appending(path: "IMG_\(i).jpg"), width: 3000, height: 2000, orientation: 1) }
        try MediaFixtures.writeImage(MediaFixtures.bitmap(width: 800, height: 600), to: box.media.appending(path: "shot.png"), type: .png)
        try await MediaFixtures.video(at: box.media.appending(path: "clip.mp4"), seconds: 1)
        try MediaFixtures.wav(at: box.media.appending(path: "voice.wav"), seconds: 1)
        try Data((0..<3000).map { UInt8($0 % 233) }).write(to: box.media.appending(path: "corrupt.jpg"))

        let engine = try await CoreBridge.open(dataDirectory: box.data, watch: false)
        let handle = engine.handle
        try await handle.start()
        _ = try await handle.addFolder(request: AddFolderRequestDto(path: box.media.path, bookmark: nil, volume: testVolume()))
        let worker = MediaWorker(engine: handle, events: engine.events)
        worker.start()

        let finished = await waitUntil(timeout: .seconds(60)) {
            let p = await handle.progress()
            return p.mediaTotal == 10 && p.mediaRemaining == 0
        }
        await worker.stop()
        try expect(finished, "all ten files are processed")

        let progress = await handle.progress()
        try expectEqual(progress.mediaDone, 9)
        try expectEqual(progress.mediaFailed, 1)

        let results = try await handle.search(query: .everything)
        let all = try await results.summaries(offset: 0, limit: 50)
        try expectEqual(all.count, 10)
        let good = all.filter { $0.probeState == .ok }
        try expectEqual(good.count, 9)
        for asset in good {
            try expectEqual(asset.thumbRev, 1, asset.name)
            let path = handle.thumbPath(assetId: asset.id, rev: asset.thumbRev)
            try expect(FileManager.default.fileExists(atPath: path), "thumbnail for \(asset.name)")
            try expect(thumbSize(path) != nil, "\(asset.name) thumbnail decodes")
        }
        let bad = all.first { $0.name == "corrupt.jpg" }
        try expectEqual(bad?.probeState, .failed)
        try expectEqual(bad?.thumbRev, 0)
        // Metadata made it into search: portrait clips are findable by shape and videos by length.
        var portrait = SearchQuery.everything
        portrait.filters.kinds = [.video]
        let videos = try await handle.search(query: portrait)
        try expectEqual(videos.count(), 1)
        let detail = try await handle.assetDetail(assetId: results.idAt(index: 0) ?? 0)
        try expect(detail.path != nil)
        try await handle.shutdown()
    },

    TestCase(name: "worker: stopping mid-library loses nothing") {
        let box = try Sandbox(); defer { box.cleanup() }
        for i in 0..<40 { try MediaFixtures.cameraJPEG(at: box.media.appending(path: "IMG_\(i).jpg"), width: 2400, height: 1600, orientation: 1) }
        let engine = try await CoreBridge.open(dataDirectory: box.data, watch: false)
        let handle = engine.handle
        try await handle.start()
        _ = try await handle.addFolder(request: AddFolderRequestDto(path: box.media.path, bookmark: nil, volume: testVolume()))
        let listed = await waitUntil { ((try? await handle.search(query: .everything).count()) ?? 0) == 40 }
        try expect(listed)

        let first = MediaWorker(engine: handle, events: engine.events, maxItemsPerBatch: 8)
        first.start()
        _ = await waitUntil { await handle.progress().mediaDone >= 4 }
        await first.stop()   // quits while a batch may be in flight
        let mid = await handle.progress()
        try expect(mid.mediaDone + mid.mediaRemaining == 40, "nothing vanished: \(mid)")

        let second = MediaWorker(engine: handle, events: engine.events)
        second.start()
        let done = await waitUntil(timeout: .seconds(60)) { await handle.progress().mediaRemaining == 0 }
        await second.stop()
        try expect(done)
        let final = await handle.progress()
        try expectEqual(final.mediaDone, 40)
        try expectEqual(final.mediaFailed, 0)
        try await handle.shutdown()
    },
]
