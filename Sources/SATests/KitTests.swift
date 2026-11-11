// Pure logic from SmartAssetKit: names, formats, EXIF dates, filter merging, sidebar keys, model recommendation.
import CoreBridge
import Foundation
import SmartAssetKit

let kitTests: [TestCase] = [
    TestCase(name: "kit: codec names and four-character codes") {
        try expectEqual(MediaNames.codec(fourCC: "avc1"), "H.264")
        try expectEqual(MediaNames.codec(fourCC: "hvc1"), "HEVC")
        try expectEqual(MediaNames.codec(fourCC: "apch"), "ProRes 422 HQ")
        try expectEqual(MediaNames.codec(fourCC: "lpcm"), "PCM")
        try expectEqual(MediaNames.codec(fourCC: "zzzz"), "ZZZZ", "unknown codes are shown, not hidden")
        try expectEqual(MediaNames.fourCCString(0x61766331), "avc1")
        try expectEqual(MediaNames.fourCCString(0x00000001), "???\u{0}".replacingOccurrences(of: "\u{0}", with: "?"), "non-printable bytes never reach the screen")
    },

    TestCase(name: "kit: durations, sizes, shutter speeds") {
        try expectEqual(Format.duration(milliseconds: 7_000), "0:07")
        try expectEqual(Format.duration(milliseconds: 83_000), "1:23")
        try expectEqual(Format.duration(milliseconds: 3_723_000), "1:02:03")
        try expectEqual(Format.duration(milliseconds: -5), "0:00")
        try expectEqual(Format.dimensions(width: 4000, height: 3000), "4000 × 3000")
        try expectEqual(Format.dimensions(width: nil, height: 3000), nil)
        try expectEqual(Format.frameRate(24), "24 fps")
        try expectEqual(Format.frameRate(29.97), "29.97 fps")
        try expectEqual(ExifFormat.shutter(0.004), "1/250 s")
        try expectEqual(ExifFormat.shutter(2), "2 s")
        try expectEqual(ExifFormat.shutter(2.5), "2.5 s")
        try expectEqual(ExifFormat.aperture(2.8), "f/2.8")
        try expectEqual(ExifFormat.focalLength(34.6), "35 mm")
    },

    TestCase(name: "kit: camera dates with and without an offset; bad dates are rejected") {
        try expectEqual(ExifFormat.captureDate("2024:03:05 14:22:01", offset: "+02:00"), 1_709_641_321_000)
        try expectEqual(ExifFormat.captureDate("2024:03:05 14:22:01", offset: "Z"), 1_709_648_521_000)
        try expectEqual(ExifFormat.captureDate("2024:03:05 14:22:01", offset: "-0530"), 1_709_668_321_000)
        let withFraction = ExifFormat.captureDate("2024:03:05 14:22:01", offset: "Z", subsecond: "50")
        try expectEqual(withFraction, 1_709_648_521_500)
        for bad in ["0000:00:00 00:00:00", "", "garbage", "2024:13:05 14:22:01", "2024:03:05 25:00:00"] {
            try expectEqual(ExifFormat.captureDate(bad), nil, "\(bad)")
        }
        try expectEqual(ExifFormat.signedCoordinate(122.4194, reference: "W"), -122.4194)
        try expectEqual(ExifFormat.signedCoordinate(37.7, reference: "N"), 37.7)
        try expectEqual(ExifFormat.signedCoordinate(33.9, reference: "S"), -33.9)
    },

    TestCase(name: "kit: QuickTime location strings") {
        let sf = Iso6709.parse("+37.7749-122.4194+012.000/")
        try expectEqual(sf?.latitude, 37.7749)
        try expectEqual(sf?.longitude, -122.4194)
        let south = Iso6709.parse("-33.8688+151.2093/")
        try expectEqual(south?.latitude, -33.8688)
        try expectEqual(south?.longitude, 151.2093)
        for bad in ["", "abc", "+95.0+10.0/", "+10.0+200.0/", "+10.0/"] { try expect(Iso6709.parse(bad) == nil, "\(bad)") }
    },

    TestCase(name: "kit: sidebar pages round-trip through their stored form") {
        let items: [SidebarItem] = [.search, .all, .missing, .kind(.image), .kind(.video), .kind(.audio), .folder(7), .collection(3), .smart(9), .tag("b-roll: night")]
        for item in items {
            try expectEqual(SidebarItem(storageKey: item.storageKey), item, item.storageKey)
        }
        for bad in ["", "folder:x", "kind:document", "nonsense", "collection"] { try expect(SidebarItem(storageKey: bad) == nil, "\(bad)") }
        try expectEqual(SidebarItem.folder(4).baseFilters().folderIds, [4])
        try expectEqual(SidebarItem.missing.baseFilters().missing, .only)
        try expectEqual(SidebarItem.kind(.video).baseFilters().kinds, [.video])
        try expect(SidebarItem.all.baseFilters().isEmpty)
        try expect(SidebarItem.search.baseFilters().isEmpty, "Search looks everywhere until a scope is chosen")
    },

    TestCase(name: "kit: a search scope narrows to one place, and a library page implies its own") {
        try expect(SearchScope.everywhere.filters.isEmpty)
        try expectEqual(SearchScope.folder(4).filters.folderIds, [4])
        try expectEqual(SearchScope.collection(2).filters.collectionId, 2)
        try expectEqual(SearchScope.tag("hero").filters.tagsAll, ["hero"])
        try expectEqual(SearchScope(page: .folder(9)), .folder(9))
        try expectEqual(SearchScope(page: .tag("iceland")), .tag("iceland"))
        try expectEqual(SearchScope(page: .all), .everywhere)
        try expectEqual(SearchScope(page: .duplicates), .everywhere)
    },

    TestCase(name: "kit: a video's scenes start where the picture changes, never closer than two seconds, never more than sixteen") {
        // Ten instants, two seconds apart; the picture changes at 3 (dark to light) and 7 (light to mid).
        let times = (0..<10).map { Double($0) * 2 + 1 }
        let dark = [UInt8](repeating: 20, count: 144), light = [UInt8](repeating: 220, count: 144), mid = [UInt8](repeating: 120, count: 144)
        let shots = (0..<10).map { $0 < 3 ? dark : ($0 < 7 ? light : mid) }
        try expectEqual(SceneSelector.select(times: times, signatures: shots, duration: 20), [1, 7, 15])
        // Nothing changes: still described at a few places along it, in time order.
        let still = Array(repeating: dark, count: 10)
        let spread = SceneSelector.select(times: times, signatures: still, duration: 20)
        try expectEqual(spread.count, SceneSelector.minimumScenes)
        try expectEqual(spread, spread.sorted())
        try expectEqual(spread.first, 1)
        // A flicker half a second apart is not scenes (closer than the gap); the video still gets its minimum of three.
        let flicker: [[UInt8]] = [dark, light, dark, light]
        try expectEqual(SceneSelector.select(times: [0.5, 1.0, 1.5, 2.0], signatures: flicker, duration: 2).count, SceneSelector.minimumScenes)
        // A music video with a cut at every instant keeps at most sixteen, spread over its length, first and last included.
        let many = (0..<60).map { Double($0) * 3 }
        let strobe: [[UInt8]] = (0..<60).map { [UInt8](repeating: $0 % 2 == 0 ? 0 : 255, count: 144) }
        let kept = SceneSelector.select(times: many, signatures: strobe, duration: 180)
        try expectEqual(kept.count, SceneSelector.maximumScenes)
        try expectEqual(kept.first, 0)
        try expectEqual(kept.last, 177)
        // Degenerate input is answered with nothing, never a crash.
        try expect(SceneSelector.select(times: [], signatures: [], duration: 0).isEmpty)
        try expect(SceneSelector.select(times: [1, 2], signatures: [dark], duration: 5).isEmpty, "mismatched lengths")
        try expectEqual(SceneSelector.change([0, 0], [255, 255]), 1.0)
        try expectEqual(SceneSelector.change([1], [1, 2]), 0)
        // Instants to look at: one a second for short videos, at most 96 for long ones, none for no length.
        try expectEqual(SceneSelector.candidateTimes(duration: 30).count, 30)
        try expectEqual(SceneSelector.candidateTimes(duration: 3).count, 6)
        try expectEqual(SceneSelector.candidateTimes(duration: 3600).count, 96)
        try expect(abs((SceneSelector.candidateTimes(duration: 3600).last ?? 0) - (3600 - 3600.0 / 192)) < 0.001, "evenly spread, centred in each slot")
        try expect(SceneSelector.candidateTimes(duration: 0).isEmpty && SceneSelector.candidateTimes(duration: .nan).isEmpty)
    },

    TestCase(name: "kit: model downloads come only from the pinned commit on Hugging Face, over HTTPS") {
        let m = PinnedModels.embeddingGemma2
        try expectEqual(m.files.count, 11)
        try expectEqual(m.totalBytes, 513_421_847)
        try expect(m.requiredFreeBytes > m.totalBytes)
        let url = m.url(for: m.files[3])?.absoluteString ?? ""
        try expectEqual(url, "https://huggingface.co/Nurymanau/EmbeddingGemma-2-MLX-Swift/resolve/06b4e075e6b3772e3c29df9f2a2ace7bd4950bdd/text-q8/model.safetensors")
        try expect(m.files.allSatisfy { $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) }, "every pin is a full SHA-256")
        for ok in ["https://huggingface.co/x", "https://us.aws.cdn.hf.co/xet-bridge-us/abc", "https://cdn-lfs.huggingface.co/a"] {
            try expect(PinnedModels.allowsRedirect(to: URL(string: ok)!), ok)
        }
        for bad in ["http://huggingface.co/x", "https://evil.com/huggingface.co", "https://huggingface.co.evil.com/x", "https://nothf.co/x", "ftp://hf.co/x"] {
            try expect(!PinnedModels.allowsRedirect(to: URL(string: bad)!), bad)
        }
    },

    TestCase(name: "kit: a model is installed only whole and verified, and replaced in one step") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "sa-model-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let staging = root.appending(path: "staging")
        try fm.createDirectory(at: staging.appending(path: "a"), withIntermediateDirectories: true)
        let body = Data("weights".utf8)
        try body.write(to: staging.appending(path: "a/w.bin"))
        let good = try ModelFiles.sha256(of: staging.appending(path: "a/w.bin"))
        try expectEqual(good, "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c", "SHA-256 of the bytes \"weights\"")
        func model(_ files: [PinnedFile]) -> PinnedModel {
            PinnedModel(id: "t", name: "T", publisher: "P", repository: "o/r", commit: String(repeating: "a", count: 40), license: "L", folder: "t", files: files)
        }
        let right = model([PinnedFile(path: "a/w.bin", bytes: Int64(body.count), sha256: good)])
        let none = try ModelFiles.problems(right, in: staging)
        let short = try ModelFiles.problems(model([PinnedFile(path: "a/w.bin", bytes: 3, sha256: good)]), in: staging)
        let altered = try ModelFiles.problems(model([PinnedFile(path: "a/w.bin", bytes: Int64(body.count), sha256: String(repeating: "0", count: 64))]), in: staging)
        let absent = try ModelFiles.problems(model([PinnedFile(path: "a/none.bin", bytes: 1, sha256: good)]), in: staging)
        try expect(none.isEmpty, "\(none)")
        try expectEqual(short, [.wrongSize("a/w.bin")])
        try expectEqual(altered, [.wrongChecksum("a/w.bin")])
        try expectEqual(absent, [.missing("a/none.bin")])
        let destination = root.appending(path: "Models/t")
        try ModelFiles.install(right, from: staging, to: destination)
        try expect(ModelFiles.isInstalled(right, in: destination), "installed and recognised")
        try expect(!fm.fileExists(atPath: staging.path), "the staging folder was moved, not copied")
        // A second install replaces the first in one step.
        let staging2 = root.appending(path: "staging2")
        try fm.createDirectory(at: staging2.appending(path: "a"), withIntermediateDirectories: true)
        try body.write(to: staging2.appending(path: "a/w.bin"))
        try ModelFiles.install(right, from: staging2, to: destination)
        try expect(ModelFiles.isInstalled(right, in: destination))
        // Another commit, or a damaged file, is not "installed".
        let other = PinnedModel(id: "t", name: "T", publisher: "P", repository: "o/r", commit: String(repeating: "b", count: 40), license: "L", folder: "t", files: right.files)
        try expect(!ModelFiles.isInstalled(other, in: destination))
        try Data("x".utf8).write(to: destination.appending(path: "a/w.bin"))
        try expect(!ModelFiles.isInstalled(right, in: destination), "a file of the wrong size is not an install")
    },

    TestCase(name: "kit: recent searches keep the newest first, drop repeats and blanks, and stop at ten") {
        var recent = RecentSearches()
        recent.add("   ")
        recent.add("a")
        try expect(recent.items.isEmpty, "blank and one-letter searches are not remembered")
        recent.add("drone  shot")
        recent.add("street night")
        recent.add("Drone shot")
        try expectEqual(recent.items, ["Drone shot", "street night"])
        for n in 0..<15 { recent.add("query \(n)") }
        try expectEqual(recent.items.count, RecentSearches.limit)
        try expectEqual(recent.items.first, "query 14")
        recent.remove("query 14")
        try expectEqual(recent.items.first, "query 13")
        recent.clear()
        try expect(recent.items.isEmpty)
    },

    TestCase(name: "kit: chips laid over a page narrow it the way people expect") {
        var base = Filters.none
        base.kinds = [.video]
        base.tagsAll = ["Travel"]
        var chips = Filters.none
        chips.minRating = 4
        chips.tagsAll = ["travel", "b-roll"]
        chips.kinds = [.image]
        let merged = chips.merged(over: base)
        try expectEqual(merged.kinds, [.image], "a kind chosen with chips replaces the page's")
        try expectEqual(merged.minRating, 4)
        try expectEqual(merged.tagsAll, ["Travel", "b-roll"], "required tags add up without duplicates, ignoring case")
        try expect(Filters.none.merged(over: base) == base, "no chips leaves the page unchanged")
        try expect(Filters.none.isEmpty && !merged.isEmpty)
    },

    TestCase(name: "kit: filter chips describe the active conditions in plain words") {
        var f = Filters.none
        f.kinds = [.video]
        f.minResolution = .uhd4k
        f.minRating = 3
        f.minDurationMs = 120_000
        f.flag = .pick
        let titles = FilterText.chips(for: f).map(\.title)
        try expectEqual(titles, ["Videos", "4K+", "Over 2:00", "★★★ & up", "Picks"])
        try expect(FilterText.chips(for: .none).isEmpty)
    },

    TestCase(name: "kit: sort choices have distinct, readable names") {
        let titles = SortChoice.menu.map(\.title)
        try expectEqual(Set(titles).count, titles.count)
        try expectEqual(SortChoice.newest.title, "Date (Newest First)")
        try expectEqual(SortChoice.newest.sort.key, .dateCaptured)
        try expect(SortChoice.newest.sort.descending)
    },

    TestCase(name: "kit: the model recommendation follows the memory tier (plan D5)") {
        try expectEqual(ModelCatalog.recommendedTranscription(memoryGigabytes: 8), "whisper-small")
        try expectEqual(ModelCatalog.recommendedTranscription(memoryGigabytes: 16), "whisper-large-v3-turbo")
        try expectEqual(ModelCatalog.recommendedTranscription(memoryGigabytes: 24), "whisper-large-v3-turbo")
        try expectEqual(ModelCatalog.sizeText(nil), "Size shown when available")
        try expectEqual(ModelCatalog.sizeText(1.6), "About 1.6 GB")
        try expectEqual(ModelCatalog.sizeText(0.5), "About 500 MB")
        // Nothing here may claim a model is downloadable before it is built.
        try expect(ModelCatalog.entries.allSatisfy { if case .planned = $0.availability { true } else { false } })
        try expectEqual(Set(ModelCatalog.entries.map(\.id)).count, ModelCatalog.entries.count)
    },
]
