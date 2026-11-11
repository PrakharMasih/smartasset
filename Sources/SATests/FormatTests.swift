// Every format from plan L6, on real files: generated where an encoder exists, real camera files for RAW.
import AVFoundation
import CoreBridge
import DemoMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Workers

/// Where sample files live between runs. RAW files are real, public-domain camera files (raw.pixls.us).
private let fixtureRoot = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Developer/SmartAsset/fixtures", directoryHint: .isDirectory)

private func tool(_ name: String) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/usr/sbin"] {
        let path = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

@discardableResult
private func run(_ tool: String, _ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

private func task(_ url: URL, kind: MediaKind, thumbs: URL) -> MediaTaskDto {
    MediaTaskDto(jobId: 1, assetId: 1, path: url.path, kind: kind, ext: url.pathExtension.lowercased(),
                 thumbPath: thumbs.appending(path: "t_\(UUID().uuidString).jpg").path, thumbRev: 1, maxEdge: 512, attempt: 1)
}

private func thumbSize(_ path: String) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

private func process(_ url: URL, kind: MediaKind, box: Sandbox) async throws -> (ProbeDto, (Int, Int)?, Duration) {
    let t = task(url, kind: kind, thumbs: box.root)
    let started = ContinuousClock.now
    let outcome = await MediaProcessor.process(t)
    let elapsed = started.duration(to: .now)
    switch outcome {
    case .done(let probe, let wrote):
        try expect(wrote, "\(url.lastPathComponent): thumbnail written")
        return (probe, thumbSize(t.thumbPath), elapsed)
    case .failed(let errorClass, let message):
        throw fail("\(url.lastPathComponent) failed: \(errorClass) \(message)")
    }
}

let formatTests: [TestCase] = [
    TestCase(name: "formats: real camera RAW files (CR3, NEF, ARW, RAF, ORF, RW2, DNG)") {
        let dir = fixtureRoot.appending(path: "raw")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["cr3", "nef", "arw", "raf", "orf", "rw2", "dng"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw Unverified(reason: "no RAW samples in \(dir.path) (download from raw.pixls.us)") }
        let box = try Sandbox(); defer { box.cleanup() }
        var report: [String] = []
        var problems: [String] = []
        for file in files {
            do {
                let (probe, thumb, elapsed) = try await process(file, kind: .image, box: box)
                if (probe.width ?? 0) < 400 || (probe.height ?? 0) < 300 { problems.append("\(file.lastPathComponent): dimensions \(String(describing: probe.width))x\(String(describing: probe.height))") }
                if thumb == nil || max(thumb!.0, thumb!.1) < 256 { problems.append("\(file.lastPathComponent): thumbnail \(String(describing: thumb))") }
                if elapsed > .seconds(8) { problems.append("\(file.lastPathComponent): took \(elapsed)") }
                report.append("\(file.pathExtension.uppercased()) \(probe.width ?? 0)×\(probe.height ?? 0) \(probe.cameraMake ?? "?") \(elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow)))")
            } catch { problems.append("\(file.lastPathComponent): \(error)") }
        }
        print("      " + report.joined(separator: "; "))
        try expect(problems.isEmpty, problems.joined(separator: " | "))
    },

    TestCase(name: "formats: RAW from cameras macOS does not support fail as unsupported, not corrupt") {
        let dir = fixtureRoot.appending(path: "raw-unsupported")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { throw Unverified(reason: "no samples in \(dir.path)") }
        let box = try Sandbox(); defer { box.cleanup() }
        for file in files {
            let t = task(file, kind: .image, thumbs: box.root)
            switch await MediaProcessor.process(t) {
            case .done:
                continue // a newer macOS may read it; that is fine
            case .failed(let errorClass, let message):
                try expectEqual(errorClass, .unsupported, "\(file.lastPathComponent): \(message)")
                try expect(message.contains("RAW"), "the message names the problem: \(message)")
                try expect(!FileManager.default.fileExists(atPath: t.thumbPath))
            }
        }
    },

    TestCase(name: "formats: WebP") {
        guard let cwebp = tool("cwebp") else { throw Unverified(reason: "cwebp not installed") }
        let box = try Sandbox(); defer { box.cleanup() }
        let png = box.media.appending(path: "src.png"), webp = box.media.appending(path: "photo.webp")
        try MediaFixtures.writeImage(MediaFixtures.bitmap(width: 1200, height: 800), to: png, type: .png)
        let status = try run(cwebp, ["-q", "80", png.path, "-o", webp.path])
        try expectEqual(status, 0, "cwebp")
        let (probe, thumb, _) = try await process(webp, kind: .image, box: box)
        try expectEqual(probe.width, 1200)
        try expectEqual(probe.height, 800)
        try expect(thumb != nil)
    },

    TestCase(name: "formats: HEVC, ProRes and M4V video") {
        let box = try Sandbox(); defer { box.cleanup() }
        let cases: [(String, AVVideoCodecType, AVFileType, String)] = [
            ("hevc.mov", .hevc, .mov, "HEVC"),
            ("prores.mov", .proRes422, .mov, "ProRes 422"),
            ("clip.m4v", .h264, .m4v, "H.264"),
        ]
        for (name, codec, fileType, expectedCodec) in cases {
            let url = box.media.appending(path: name)
            do {
                try await MediaFixtures.video(at: url, width: 640, height: 360, seconds: 1, codec: codec, fileType: fileType)
            } catch {
                throw Unverified(reason: "this Mac cannot write \(name): \(error.localizedDescription)")
            }
            let (probe, thumb, _) = try await process(url, kind: .video, box: box)
            try expectEqual(probe.codec, expectedCodec, name)
            try expectEqual(probe.width, 640, name)
            try expect(abs(Double(probe.durationMs ?? 0) - 1000) < 200, "\(name) duration \(String(describing: probe.durationMs))")
            try expect(thumb != nil, "\(name) poster frame")
        }
    },

    TestCase(name: "formats: AIFF, AAC/M4A, FLAC and MP3 audio") {
        let box = try Sandbox(); defer { box.cleanup() }
        let wav = box.media.appending(path: "src.wav")
        try MediaFixtures.wav(at: wav, seconds: 2)
        var made: [(URL, String)] = []
        if let afconvert = tool("afconvert") {
            for (name, args, codec) in [("tone.aiff", ["-f", "AIFF", "-d", "BEI16"], "PCM"),
                                        ("tone.m4a", ["-f", "m4af", "-d", "aac"], "AAC"),
                                        ("tone.flac", ["-f", "flac", "-d", "flac"], "FLAC")] {
                let out = box.media.appending(path: name)
                if try run(afconvert, [wav.path, out.path] + args) == 0 { made.append((out, codec)) }
            }
        }
        if let lame = tool("lame") {
            let out = box.media.appending(path: "tone.mp3")
            if try run(lame, ["--silent", wav.path, out.path]) == 0 { made.append((out, "MP3")) }
        }
        guard made.count >= 3 else { throw Unverified(reason: "could only encode \(made.map(\.0.lastPathComponent)); need afconvert and lame") }
        var covered: [String] = []
        for (url, codec) in made {
            let (probe, thumb, _) = try await process(url, kind: .audio, box: box)
            try expect(abs(Double(probe.durationMs ?? 0) - 2000) < 250, "\(url.lastPathComponent) duration \(String(describing: probe.durationMs))")
            try expectEqual(probe.codec, codec, url.lastPathComponent)
            try expect(probe.sampleRate == 44_100 || probe.sampleRate == 48_000, "\(url.lastPathComponent) rate \(String(describing: probe.sampleRate))")
            try expectEqual(thumb?.0, 512, "\(url.lastPathComponent) waveform")
            covered.append(url.pathExtension.uppercased())
        }
        print("      covered: \(covered.joined(separator: ", "))")
        if made.count < 4 { throw Unverified(reason: "only \(covered.joined(separator: ", ")) were encoded; the rest need their encoder") }
    },
]
