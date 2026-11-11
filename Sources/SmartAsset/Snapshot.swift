// Screenshot mode for agents and design review (bama build-and-verify).
//   APP_DATA=/tmp/sa-data APP_DEMO=1 APP_SNAPSHOT=/tmp/sa-shots SmartAsset
// writes PNGs of each screen in light and dark, then quits. Add APP_SNAPSHOT_EMPTY=1 for the first-launch screen.
import AppKit
import CoreBridge
import ImageIO
import IOKit.pwr_mgt
import SmartAssetKit
import SwiftUI

enum Snapshot {
    static func runIfRequested(model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty else { return }
        // Snapshots never run against the real library.
        let data = AppModel.dataDirectory.path
        guard ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].contains(where: { data.hasPrefix($0) }) else {
            print("SNAPSHOT refused: set APP_DATA to a folder in /tmp")
            NSApp.terminate(nil)
            return
        }
        // A sleeping display gives screencapture nothing.
        var assertion: IOPMAssertionID = 0
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &assertion)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        model.inspectorVisible = true

        if env["APP_SNAPSHOT_EMPTY"] == "1" {
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                await sleep(1.2)
                await shoot(dir, "welcome-\(mode)")
            }
        } else {
            do {
                if DemoLibrary.isRequested {
                    let media = URL(fileURLWithPath: data).deletingLastPathComponent().appending(path: "sa-demo-media")
                    let expected = try await DemoLibrary.make(at: media)
                    await model.addFolders([media.appending(path: "Iceland Trip"), media.appending(path: "Studio Shoot"), media.appending(path: "Street")])
                    let done = await waitFor(timeout: 120) { Int(model.stats?.total ?? 0) >= expected && (model.progress?.mediaRemaining ?? 1) == 0 && !(model.progress?.scanning ?? true) }
                    print("SNAPSHOT library ready: \(done), \(model.stats?.total ?? 0) files")
                    await decorate(model)
                }
            } catch {
                print("SNAPSHOT demo failed: \(error)")
            }
            await sleep(1)
            if env["APP_SNAPSHOT_ONLY"] == "missing" {
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    model.sidebar = .missing
                    await sleep(1.5)
                    await shoot(dir, "missing-\(mode)")
                }
            } else {
                await walkThrough(model, dir: dir)
            }
        }
        print("SNAPSHOT done \(dir)")
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        // Shut down first: NSApp.terminate would spin a nested loop while this task still holds the main actor.
        await model.shutdown()
        NSApp.terminate(nil)
    }

    /// Ratings, flags, labels, tags and a collection, so the screens show them.
    private static func decorate(_ model: AppModel) async {
        guard let handle = model.handle, let all = try? await handle.search(query: .everything).allIds(), all.count > 20 else { return }
        try? await handle.setRating(assetIds: Array(all[0..<6]), rating: 5)
        try? await handle.setRating(assetIds: Array(all[6..<14]), rating: 3)
        try? await handle.setFlag(assetIds: Array(all[0..<3]), flag: .pick)
        try? await handle.setFlag(assetIds: [all[7]], flag: .reject)
        try? await handle.setColorLabel(assetIds: Array(all[2..<6]), label: .green)
        try? await handle.setColorLabel(assetIds: [all[9], all[10]], label: .red)
        try? await handle.addTags(assetIds: Array(all[0..<9]), names: ["hero", "b-roll"])
        try? await handle.addTags(assetIds: Array(all[3..<12]), names: ["iceland"])
        if let c = try? await handle.createCollection(name: "Reel Selects") { _ = try? await handle.addToCollection(id: c, assetIds: Array(all[0..<8])) }
        var q = SearchQuery.everything
        q.filters.minRating = 4
        _ = try? await handle.createSmartCollection(name: "Four Stars & Up", query: q)
        await model.refreshSidebarData()
        model.requery()
        // One file disappears from disk, so the Missing page has something to show.
        let media = URL(fileURLWithPath: AppModel.dataDirectory.path).deletingLastPathComponent().appending(path: "sa-demo-media")
        try? FileManager.default.removeItem(at: media.appending(path: "Street/ambience.wav"))
        try? await handle.rescan(folderId: nil)
        _ = await waitFor(timeout: 20) { (model.stats?.missing ?? 0) > 0 }
        await model.refreshSidebarData()
    }

    private static func walkThrough(_ model: AppModel, dir: String) async {
        for mode in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
            model.viewMode = .grid
            model.sidebar = .all
            model.clearFilters()
            model.selectedIDs = []
            await sleep(1.2)
            await shoot(dir, "grid-\(mode)")

            if let first = model.source?.id(at: 0) {
                model.selectedIDs = [first]
                await sleep(1.0)
                await shoot(dir, "grid-selected-\(mode)")
            }
            if let ids = model.results?.idsIn(offset: 2, limit: 3), ids.count == 3 {
                model.selectedIDs = Set(ids)
                await sleep(0.8)
                await shoot(dir, "grid-multi-\(mode)")
            }
            model.selectedIDs = []

            model.viewMode = .list
            await sleep(1.0)
            await shoot(dir, "list-\(mode)")
            model.viewMode = .grid

            if let folder = model.folders.first { model.sidebar = .folder(folder.id) }
            await sleep(0.9)
            await shoot(dir, "folder-\(mode)")

            model.sidebar = .all
            model.filters.kinds = [.video]
            await sleep(0.9)
            await shoot(dir, "filtered-\(mode)")
            model.clearFilters()

            model.searchText = "zzzzqq"
            await sleep(1.0)
            await shoot(dir, "no-results-\(mode)")
            model.clearFilters()

            await searchPage(model, dir: dir, mode: mode)

            if let collection = model.collections.first { model.sidebar = .collection(collection.id) }
            await sleep(0.9)
            await shoot(dir, "collection-\(mode)")
            model.sidebar = .all

            if (model.stats?.missing ?? 0) > 0 {
                model.sidebar = .missing
                await sleep(1.0)
                if let first = model.source?.id(at: 0) { model.selectedIDs = [first] }
                await sleep(0.9)
                await shoot(dir, "missing-\(mode)")
                model.selectedIDs = []
                model.sidebar = .all
            }

            await duplicates(model, dir: dir, mode: mode)
            await settings(model, dir: dir, mode: mode)
            await viewers(model, dir: dir, mode: mode)
            await zoomMid(model, dir: dir, mode: mode)
        }
    }

    /// The Search page: the invitation, results, a search inside one folder, and a question nothing answers.
    private static func searchPage(_ model: AppModel, dir: String, mode: String) async {
        model.newSearch()
        model.sidebar = .search
        await sleep(0.9)
        await shoot(dir, "search-home-\(mode)")
        model.recentSearches.add("golden hour drone shot")
        model.recentSearches.add("street at night")
        await sleep(0.5)
        await shoot(dir, "search-home-recent-\(mode)")
        model.searchText = "img"
        await sleep(1.5)
        await shoot(dir, "search-results-\(mode)")
        if let first = model.source?.id(at: 0) {
            model.selectedIDs = [first]
            await sleep(1.0)
            await shoot(dir, "search-selected-\(mode)")
            model.selectedIDs = []
        }
        // More Like This (S7): the chip in the field. Snapshot runs have no model, so the file has no description and the
        // page shows the "Not Looked At Yet" state; the filled results are the ordinary grid and are covered by the self-test.
        if let first = model.source?.id(at: 0), let summary = try? await model.handle?.summaries(assetIds: [first]).first {
            model.searchText = ""
            model.searchLike = AppModel.LikeTarget(id: first, name: summary.name)
            await sleep(1.2)
            await shoot(dir, "search-like-\(mode)")
            model.searchLike = nil
            model.searchText = "img"
            await sleep(1.0)
        }
        if let folder = model.folders.first {
            model.searchScope = .folder(folder.id)
            await sleep(1.0)
            await shoot(dir, "search-scoped-\(mode)")
        }
        model.searchText = "zzzzqq"
        await sleep(1.0)
        await shoot(dir, "search-none-\(mode)")
        model.newSearch()
        model.recentSearches.clear()
        model.sidebar = .all
        await sleep(0.4)
    }

    /// A tile opening the Viewer, caught part-way (the zoom is slowed in snapshot runs): the whole screen, because the
    /// flying picture is a panel of its own.
    private static func zoomMid(_ model: AppModel, dir: String, mode: String) async {
        model.sidebar = .all
        model.viewMode = .grid
        model.selectedIDs = []
        await sleep(1.2)
        guard let window = mainWindow(),
              let collection = window.contentView?.superview?.firstDescendant(where: { $0 is AssetCollectionView }) as? AssetCollectionView,
              let coordinator = collection.delegate as? AssetGridView.Coordinator else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(collection)
        collection.selectionIndexPaths = [IndexPath(item: 5, section: 0)]
        coordinator.selectionChanged()
        await sleep(0.8)
        coordinator.openViewer()
        await sleep(0.45)
        let path = "\(dir)/viewer-zoom-mid-\(mode).png"
        try? FileManager.default.removeItem(atPath: path)
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", path]
        try? shot.run()
        shot.waitUntilExit()
        print("SNAPSHOT \(path)")
        await sleep(1.6)
        for w in NSApp.windows where w.identifier?.rawValue.lowercased().contains("viewer") == true { w.close() }
        await sleep(0.4)
    }

    /// The Duplicates page: exact copies, look-alikes, copies ticked, and the review before anything moves.
    private static func duplicates(_ model: AppModel, dir: String, mode: String) async {
        model.sidebar = .duplicates
        let found = await waitFor(timeout: 90) {
            guard let d = model.duplicates else { return false }
            return !d.exact.isEmpty && d.hashRemaining == 0 && d.perceptualRemaining == 0
        }
        print("SNAPSHOT duplicates ready: \(found), \(model.duplicates?.exact.count ?? 0) exact, \(model.duplicates?.similar.count ?? 0) similar")
        model.duplicateTab = .exact
        await sleep(1.8)
        await shoot(dir, "duplicates-exact-\(mode)")

        if let group = model.duplicates?.exact.first,
           let copies = Optional(group.members.map { AppModel.copy($0, online: true) }) {
            model.selectExtraCopies(in: group, copies: copies)
            await sleep(0.8)
            await shoot(dir, "duplicates-ticked-\(mode)")
            await model.reviewCleanup(of: group)
            await sleep(1.2)
            if let w = NSApp.windows.first(where: { $0.isSheet }) ?? mainWindow()?.attachedSheet {
                capture(to: "\(dir)/duplicates-review-\(mode).png", window: w)
            }
            model.cancelCleanupReview()
            await sleep(0.5)
            model.clearTicks(in: group.key)
        }
        model.duplicateTab = .similar
        await sleep(1.5)
        await shoot(dir, "duplicates-similar-\(mode)")
        model.duplicateTab = .exact
        model.sidebar = .all
    }

    private static func settings(_ model: AppModel, dir: String, mode: String) async {
        model.openSettingsAction?()
        await sleep(1.2)
        for tab in SettingsTab.allCases {
            model.settingsTab = tab
            await sleep(0.7)
            if let w = NSApp.windows.first(where: { $0 !== mainWindow() && $0.isVisible && $0.canBecomeKey && $0.identifier?.rawValue.lowercased().contains("viewer") != true }) {
                capture(to: "\(dir)/settings-\(tab.rawValue)-\(mode).png", window: w)
            }
        }
        NSApp.windows.first { $0 !== mainWindow() && $0.isVisible && $0.identifier?.rawValue.lowercased().contains("viewer") != true }?.close()
        await sleep(0.4)
    }

    private static func viewers(_ model: AppModel, dir: String, mode: String) async {
        let kinds: [(MediaKind, String)] = [(.image, "image"), (.video, "video"), (.audio, "audio")]
        for (kind, name) in kinds {
            var q = SearchQuery.everything
            q.filters.kinds = [kind]
            guard let id = (try? await model.handle?.search(query: q))?.idAt(index: 0) else { continue }
            model.openViewer(id)
            await sleep(1.8)
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.lowercased().contains("viewer") == true }) {
                capture(to: "\(dir)/viewer-\(name)-\(mode).png", window: w)
                w.close()
            }
            await sleep(0.4)
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !$0.isSheet && $0.identifier?.rawValue.lowercased().contains("main") == true }
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !$0.isSheet }
    }

    private static func shoot(_ dir: String, _ name: String) async {
        capture(to: "\(dir)/\(name).png", window: mainWindow())
    }

    private static func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func waitFor(timeout: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    /// Captures the real window with screencapture, so glass, sidebars and materials look as on screen. That needs
    /// Screen Recording permission for the app that started this one. Without it, falls back to drawing the view
    /// hierarchy, which leaves sidebars blank.
    private static func capture(to path: String, window: NSWindow?) {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window else { print("SNAPSHOT no window for \(path)"); return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: window.contentView?.bounds.size ?? .zero)
        try? FileManager.default.removeItem(atPath: path)
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) { print("SNAPSHOT \(path)"); return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, sidebars and glass are blank)")
        }
    }
}
