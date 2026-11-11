// Phase 2: the rules of the Duplicates page, the perceptual hash, and the labeled-set measurements of near-duplicate
// matching (plan A2). The labeled sets run real files through the real worker pipeline and the real matcher.
import AVFoundation
import CoreBridge
import CoreGraphics
import CoreImage
import DemoMedia
import Foundation
import ImageIO
import SmartAssetKit
import UniformTypeIdentifiers
import Workers

private let fixtureRoot = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Developer/SmartAsset/fixtures", directoryHint: .isDirectory)

let duplicateTests: [TestCase] = [
    TestCase(name: "duplicates: ticking rules keep one copy and skip drives that are away") {
        let a = DuplicateTicks.Copy(id: 1, suggestedKeep: true, online: true)
        let b = DuplicateTicks.Copy(id: 2, suggestedKeep: false, online: true)
        let c = DuplicateTicks.Copy(id: 3, suggestedKeep: false, online: true)
        let away = DuplicateTicks.Copy(id: 4, suggestedKeep: false, online: false)
        let group = [a, b, c, away]

        try expectEqual(DuplicateTicks.extraCopies(in: group), [2, 3], "the suggested copy and the one that is away are not ticked")
        try expect(DuplicateTicks.canTick(b, in: group, ticked: []))
        try expect(!DuplicateTicks.canTick(away, in: group, ticked: []), "a file on an unplugged drive cannot be moved")
        // With two of three connected copies ticked, the last connected one (plus the away one) still stays: allowed.
        try expect(DuplicateTicks.canTick(c, in: group, ticked: [2]))
        // In a pair, ticking one leaves the other; the other's box then switches off.
        let pair = [a, b]
        try expect(DuplicateTicks.canTick(b, in: pair, ticked: []))
        try expect(!DuplicateTicks.canTick(a, in: pair, ticked: [2]), "the last copy cannot be ticked")
        try expect(DuplicateTicks.canTick(b, in: pair, ticked: [2]), "an existing tick can always be removed")
        // A stale tick set that would remove every copy is cut back.
        try expectEqual(DuplicateTicks.pruned([1, 2], in: pair), [2])
        try expectEqual(DuplicateTicks.pruned([2, 99], in: pair), [2], "ticks for files that left the group are dropped")
        try expectEqual(DuplicateTicks.pruned([4], in: group), [], "a drive that went away cannot be moved")
        try expectEqual(DuplicateTicks.extraCopies(in: [DuplicateTicks.Copy(id: 7, suggestedKeep: true, online: true)]), [])
    },

    TestCase(name: "duplicates: the words come from one place and use the glossary") {
        try expectEqual(DuplicateText.groupTitle(exact: true, count: 3, kinds: [.image]), "3 exact copies")
        try expectEqual(DuplicateText.groupTitle(exact: false, count: 2, kinds: [.image]), "2 similar photos")
        try expectEqual(DuplicateText.groupTitle(exact: false, count: 2, kinds: [.video]), "2 similar videos")
        try expectEqual(DuplicateText.groupTitle(exact: false, count: 4, kinds: [.image, .video]), "4 similar files")
        try expectEqual(DuplicateText.match(percent: 100, exact: true), "Exact copy")
        try expectEqual(DuplicateText.match(percent: 94, exact: false), "94% match")
        try expectEqual(DuplicateText.reviewTitle(count: 1), "Move 1 File to the Trash?")
        try expectEqual(DuplicateText.reviewTitle(count: 3), "Move 3 Files to the Trash?")
        try expectEqual(DuplicateText.reviewButton(count: 2), "Move 2 Files to the Trash…")
        try expectEqual(DuplicateText.reviewButton(count: 0), "Move to Trash…")
        try expectEqual(DuplicateText.freed(0), "Nothing to free")
        try expect(DuplicateText.freed(5_000_000).hasSuffix("could be freed"))
        try expect(DuplicateText.trashed(count: 1, bytes: 1_000_000).hasPrefix("Moved 1 file to the Trash"))
        // Files are only ever moved to the Trash, never deleted: no string on this page says "delete".
        let all = [DuplicateText.suggestedHelp, DuplicateText.mergeNote, DuplicateText.reviewTitle(count: 2), DuplicateText.trashed(count: 2, bytes: 1)]
        try expect(all.allSatisfy { !$0.localizedCaseInsensitiveContains("delete") })
    },

    TestCase(name: "duplicates: the sidebar page is remembered between launches") {
        try expectEqual(SidebarItem.duplicates.storageKey, "duplicates")
        try expectEqual(SidebarItem(storageKey: "duplicates"), .duplicates)
        try expect(SidebarItem.duplicates.baseFilters().isEmpty, "it is not a search")
    },

    TestCase(name: "perceptual: a picture keeps its hash through a resize, and a different picture does not") {
        let a = try syntheticScene(seed: 1)
        let b = try syntheticScene(seed: 2)
        let small = try scaled(a, width: 120)
        guard let ha = Perceptual.hash(of: a), let hb = Perceptual.hash(of: b), let hSmall = Perceptual.hash(of: small) else {
            throw fail("a picture with content must have a hash")
        }
        try expectEqual(Perceptual.hash(of: a)?.phash, ha.phash, "the hash is deterministic")
        try expect(Perceptual.distance(ha.phash, hSmall.phash) <= 6, "resized copy: \(Perceptual.distance(ha.phash, hSmall.phash)) bits")
        try expect(Perceptual.distance(ha.dhash, hSmall.dhash) <= 10, "resized copy, dHash: \(Perceptual.distance(ha.dhash, hSmall.dhash)) bits")
        try expect(Perceptual.distance(ha.phash, hb.phash) >= 12, "another picture: \(Perceptual.distance(ha.phash, hb.phash)) bits")
        try expectEqual(ha.phash >> 63, 0, "bit 63 is never used")
    },

    TestCase(name: "perceptual: plain pictures have nothing to describe") {
        let solid = try solidImage(gray: 0.5)
        let black = try solidImage(gray: 0)
        try expect(Perceptual.hash(of: solid) == nil)
        try expect(Perceptual.hash(of: black) == nil)
    },

    TestCase(name: "perceptual: the worker hashes a picture from its thumbnail exactly as from the original") {
        let box = try Sandbox()
        defer { box.cleanup() }
        let scene = try syntheticScene(seed: 3, width: 1600, height: 1000)
        let original = box.root.appending(path: "scene.jpg")
        try writeJPEG(scene, to: original, quality: 0.9)
        let viaThumbnail = try await workerHash(original, box: box, useThumbnail: true)
        let viaOriginal = try await workerHash(original, box: box, useThumbnail: false)
        guard let t = viaThumbnail, let o = viaOriginal else { throw fail("the picture must be describable") }
        try expect(Perceptual.distance(t.phash, o.phash) <= 4 && Perceptual.distance(t.dhash, o.dhash) <= 6,
                   "thumbnail vs original: \(Perceptual.distance(t.phash, o.phash)) / \(Perceptual.distance(t.dhash, o.dhash)) bits")
    },

    TestCase(name: "perceptual: describing a picture from its thumbnail is cheap") {
        let photos = Array(try photoFiles().prefix(60))
        let box = try Sandbox()
        defer { box.cleanup() }
        // Make the 512 px thumbnails once, as the media pass does, then time only the hashing.
        var tasks: [PerceptualTaskDto] = []
        for (i, url) in photos.enumerated() {
            let thumb = box.root.appending(path: "t\(i).jpg").path
            let media = MediaTaskDto(jobId: 1, assetId: 1, path: url.path, kind: .image, ext: "jpg", thumbPath: thumb, thumbRev: 1, maxEdge: 512, attempt: 1)
            guard case .done = await MediaProcessor.process(media) else { throw fail("no thumbnail for \(url.lastPathComponent)") }
            tasks.append(PerceptualTaskDto(jobId: 1, assetId: 1, path: url.path, kind: .image, ext: "jpg", thumbPath: thumb, attempt: 1))
        }
        let started = ContinuousClock.now
        for t in tasks { _ = await PerceptualProcessor.process(t) }
        let ms = Double(started.duration(to: .now).components.attoseconds) / 1e15 + Double(started.duration(to: .now).components.seconds) * 1000
        let each = ms / Double(tasks.count)
        print(String(format: "  hashing: %.2f ms per picture (%d pictures, one at a time)", each, tasks.count))
        try expect(each < 25, "describing one picture takes \(each) ms")
    },

    TestCase(name: "near-duplicates: labeled set of real photos (resize, re-encode, brightness, crops)") {
        let photos = try photoFiles()
        let box = try Sandbox()
        defer { box.cleanup() }
        let eval = try await evaluatePhotos(photos, box: box)
        print(eval.report)
        let limits = defaultNearDuplicateLimits()
        let atDefault = eval.result(maxP: limits[0], maxD: limits[1])
        try expect(atDefault.falsePairs == 0, "\(atDefault.falsePairs) pictures from different photos were grouped together at the default limits")
        for name in ["resize 50%", "resize 25%", "re-encode q40", "re-encode q10", "brighter", "crop 5%"] {
            let recall = atDefault.recall[name] ?? 0
            try expect(recall >= 0.95, "recall for “\(name)” is \(Int(recall * 100))%, below 95%")
        }
    },

    TestCase(name: "near-duplicates: labeled set of videos re-encoded at other sizes and quality") {
        let photos = try photoFiles()
        let box = try Sandbox()
        defer { box.cleanup() }
        let eval = try await evaluateVideos(Array(photos.prefix(10)), box: box)
        print(eval.report)
        let limits = defaultNearDuplicateLimits()
        let atDefault = eval.result(maxP: limits[0], maxD: limits[1])
        try expect(atDefault.falsePairs == 0, "\(atDefault.falsePairs) different videos were grouped together")
        for (name, recall) in atDefault.recall { try expect(recall >= 0.9, "recall for videos “\(name)” is \(Int(recall * 100))%") }
    },
]

// MARK: - The labeled set

/// How a matcher did on a labeled set at one pair of limits.
private struct Measured {
    var falsePairs = 0
    var pairs = 0
    /// Fraction of (original, variant) pairs that ended in the same group, per kind of change.
    var recall: [String: Double] = [:]
    var precision: Double { pairs == 0 ? 1 : 1 - Double(falsePairs) / Double(pairs) }
}

private struct Evaluation {
    let items: [PerceptualItemDto]
    /// item id -> source photo
    let source: [Int64: Int]
    /// item id -> kind of change, or "original"
    let change: [Int64: String]
    let changes: [String]

    func result(maxP: UInt32, maxD: UInt32) -> Measured {
        var m = Measured()
        let groups = matchPerceptual(items: items, maxP: maxP, maxD: maxD)
        var together: Set<String> = []
        for g in groups {
            let ids = g.members.map(\.id)
            for i in 0..<ids.count {
                for j in (i + 1)..<max(i + 1, ids.count) {
                    m.pairs += 1
                    if source[ids[i]] != source[ids[j]] { m.falsePairs += 1 }
                    together.insert("\(min(ids[i], ids[j]))-\(max(ids[i], ids[j]))")
                }
            }
        }
        // Recall: each variant against the original of its own photo.
        var hit: [String: Int] = [:], total: [String: Int] = [:]
        let originals = Dictionary(uniqueKeysWithValues: items.filter { change[$0.id] == "original" }.map { (source[$0.id] ?? -1, $0.id) })
        for item in items {
            guard let kind = change[item.id], kind != "original", let o = originals[source[item.id] ?? -1] else { continue }
            total[kind, default: 0] += 1
            if together.contains("\(min(item.id, o))-\(max(item.id, o))") { hit[kind, default: 0] += 1 }
        }
        for kind in changes { m.recall[kind] = total[kind].map { Double(hit[kind] ?? 0) / Double($0) } }
        return m
    }

    /// A table of precision and recall over a grid of limits, for the roadmap.
    var report: String {
        let limits = defaultNearDuplicateLimits()
        var lines = ["", "  items: \(items.count) (\(Set(source.values).count) different photos)", "  limits (max pHash bits / max dHash bits) -> false pairs · precision · recall per change"]
        for p in [4, 6, 8, 10, 12, 14] as [UInt32] {
            for d in [6, 8, 12, 16, 20] as [UInt32] {
                let m = result(maxP: p, maxD: d)
                let recall = changes.map { "\($0) \(Int(((m.recall[$0] ?? 0) * 100).rounded()))%" }.joined(separator: ", ")
                let mark = (p == limits[0] && d == limits[1]) ? " <- default" : ""
                lines.append(String(format: "  %2d / %2d -> %3d false · %.4f · %@%@", p, d, m.falsePairs, m.precision, recall, mark))
            }
        }
        return lines.joined(separator: "\n")
    }
}

private func photoFiles() throws -> [URL] {
    let dir = fixtureRoot.appending(path: "photos", directoryHint: .isDirectory)
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "jpg" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard files.count >= 30 else {
        throw Unverified(reason: "needs 30+ real photos in \(dir.path) (tools/fetch-photo-fixtures.sh downloads 60)")
    }
    return files
}

private func evaluatePhotos(_ photos: [URL], box: Sandbox) async throws -> Evaluation {
    let changes = ["resize 50%", "resize 25%", "re-encode q40", "re-encode q10", "brighter", "less contrast", "grayscale", "crop 5%", "crop 10%", "crop 20%"]
    var items: [PerceptualItemDto] = []
    var source: [Int64: Int] = [:]
    var change: [Int64: String] = [:]
    for (index, url) in photos.enumerated() {
        guard let original = loadImage(url) else { throw fail("cannot read \(url.lastPathComponent)") }
        var variants: [(String, URL)] = [("original", url)]
        func variant(_ name: String, _ image: CGImage, quality: Double = 0.85) throws {
            let out = box.root.appending(path: "p\(index)-\(variants.count).jpg")
            try writeJPEG(image, to: out, quality: quality)
            variants.append((name, out))
        }
        try variant("resize 50%", scaled(original, width: original.width / 2))
        try variant("resize 25%", scaled(original, width: original.width / 4))
        try variant("re-encode q40", original, quality: 0.4)
        try variant("re-encode q10", original, quality: 0.1)
        try variant("brighter", adjusted(original, brightness: 0.12, contrast: 1, saturation: 1))
        try variant("less contrast", adjusted(original, brightness: 0, contrast: 0.8, saturation: 0.85))
        try variant("grayscale", adjusted(original, brightness: 0, contrast: 1, saturation: 0))
        try variant("crop 5%", cropped(original, keeping: 0.95))
        try variant("crop 10%", cropped(original, keeping: 0.90))
        try variant("crop 20%", cropped(original, keeping: 0.80))
        for (v, (name, file)) in variants.enumerated() {
            let id = Int64(index * 100 + v)
            guard let hash = try await workerHash(file, box: box, useThumbnail: true) else { continue }
            items.append(PerceptualItemDto(id: id, kind: .image, durationMs: nil, hashes: [hash]))
            source[id] = index
            change[id] = name
        }
    }
    return Evaluation(items: items, source: source, change: change, changes: changes)
}

/// Re-encodes of the same clip: a smaller picture, a lower bit rate, another codec.
private func evaluateVideos(_ photos: [URL], box: Sandbox) async throws -> Evaluation {
    let changes = ["960x540 export", "medium quality export", "HEVC export"]
    var items: [PerceptualItemDto] = []
    var source: [Int64: Int] = [:]
    var change: [Int64: String] = [:]
    let presets: [(String, String)] = [("960x540 export", AVAssetExportPreset960x540),
                                        ("medium quality export", AVAssetExportPresetMediumQuality),
                                        ("HEVC export", AVAssetExportPresetHEVC1920x1080)]
    for (index, url) in photos.enumerated() {
        guard let photo = loadImage(url) else { throw fail("cannot read \(url.lastPathComponent)") }
        let original = box.root.appending(path: "v\(index).mp4")
        try await MediaFixtures.zoomVideo(from: photo, at: original, width: 1280, height: 720, seconds: 4, fps: 24)
        var files: [(String, URL)] = [("original", original)]
        for (name, preset) in presets {
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: original), presetName: preset) else { continue }
            let out = box.root.appending(path: "v\(index)-\(files.count).mp4")
            try? FileManager.default.removeItem(at: out)
            do { try await session.export(to: out, as: .mp4) } catch { continue }
            files.append((name, out))
        }
        for (v, (name, file)) in files.enumerated() {
            let task = PerceptualTaskDto(jobId: 1, assetId: 1, path: file.path, kind: .video, ext: "mp4", thumbPath: nil, attempt: 1)
            guard case .done(let hashes) = await PerceptualProcessor.process(task), hashes.count == 3 else { continue }
            let duration = try await AVURLAsset(url: file).load(.duration).seconds
            let id = Int64(index * 100 + v)
            items.append(PerceptualItemDto(id: id, kind: .video, durationMs: Int64(duration * 1000), hashes: hashes))
            source[id] = index
            change[id] = name
        }
    }
    return Evaluation(items: items, source: source, change: change, changes: changes)
}

/// The path a real picture takes in the app: the media worker makes the 512 px thumbnail, then the perceptual worker
/// hashes it (or the original, when `useThumbnail` is false).
private func workerHash(_ file: URL, box: Sandbox, useThumbnail: Bool) async throws -> PerceptualHashDto? {
    let thumb = box.root.appending(path: "t_\(UUID().uuidString).jpg").path
    let media = MediaTaskDto(jobId: 1, assetId: 1, path: file.path, kind: .image, ext: file.pathExtension.lowercased(),
                             thumbPath: thumb, thumbRev: 1, maxEdge: 512, attempt: 1)
    guard case .done = await MediaProcessor.process(media) else { throw fail("the media worker could not read \(file.lastPathComponent)") }
    let task = PerceptualTaskDto(jobId: 1, assetId: 1, path: file.path, kind: .image, ext: file.pathExtension.lowercased(),
                                 thumbPath: useThumbnail ? thumb : nil, attempt: 1)
    switch await PerceptualProcessor.process(task) {
    case .done(let hashes): return hashes.first
    case .failed(_, let message): throw fail("hashing \(file.lastPathComponent) failed: \(message)")
    }
}

// MARK: - Picture helpers

// The variants themselves live in DemoMedia (`PhotoVariants`) so the in-app self-test measures the same set by meaning.
private func loadImage(_ url: URL) -> CGImage? { PhotoVariants.load(url) }
private func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws { try PhotoVariants.writeJPEG(image, to: url, quality: quality) }
private func context(width: Int, height: Int) throws -> CGContext { try PhotoVariants.context(width: width, height: height) }
private func scaled(_ image: CGImage, width: Int) throws -> CGImage { try PhotoVariants.scaled(image, width: width) }
private func cropped(_ image: CGImage, keeping fraction: Double) throws -> CGImage { try PhotoVariants.cropped(image, keeping: fraction) }
private func adjusted(_ image: CGImage, brightness: Double, contrast: Double, saturation: Double) throws -> CGImage {
    try PhotoVariants.adjusted(image, brightness: brightness, contrast: contrast, saturation: saturation)
}

private func solidImage(gray: Double) throws -> CGImage {
    let c = try context(width: 64, height: 64)
    c.setFillColor(gray: gray, alpha: 1)
    c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    guard let out = c.makeImage() else { throw fail("no image") }
    return out
}

/// A picture with structure at several scales, different for each seed.
private func syntheticScene(seed: UInt64, width: Int = 640, height: Int = 400) throws -> CGImage {
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 10_000) / 10_000
    }
    let c = try context(width: width, height: height)
    for band in 0..<6 {
        c.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
        c.fill(CGRect(x: 0, y: band * height / 6, width: width, height: height / 6 + 1))
    }
    for _ in 0..<14 {
        c.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
        let w = 40 + next() * 220, h = 30 + next() * 160
        c.fillEllipse(in: CGRect(x: next() * Double(width) - 40, y: next() * Double(height) - 30, width: w, height: h))
    }
    guard let out = c.makeImage() else { throw fail("no image") }
    return out
}
