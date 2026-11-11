// In-app self-test (bama test-mac-app): drives the real app, windows and views. Exit status 0 only when every check passes.
//   tools/selftest.sh        (APP_DATA in /tmp; builds a generated library, runs each check, quits)
// Covers what unit tests cannot reach: hover-scrub on real tiles, Quick Look, the drag pasteboard, a real drive being
// unplugged and replugged, a folder moved while the app is open and while it is closed, and an accessibility-tree audit.
import AppKit
import CoreBridge
import DemoMedia
import Foundation
import ApplicationServices
import QuickLookUI
import Embedding
import SmartAssetKit

enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The check could not run here; reported as UNVERIFIED, never as a pass.
    struct Unverified: Error {
        let reason: String
    }

    private struct Check {
        let name: String
        let body: @MainActor () async throws -> String
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static func runIfRequested(model: AppModel) async {
        guard requested else { return }
        let data = AppModel.dataDirectory.path
        guard ["/tmp/", "/private/tmp/"].contains(where: { data.hasPrefix($0) }) else {
            print("SELFTEST refused: APP_DATA must be a folder in /tmp")
            await finish(2, model)
        }
        let root = URL(fileURLWithPath: data).deletingLastPathComponent().appending(path: "sa-selftest-media")
        var failed = 0
        var unverified = 0
        var ran = 0
        var results: [(String, Bool, String)] = []
        do {
            let expected = try await DemoLibrary.make(at: root)
            await model.addFolders([root.appending(path: "Iceland Trip"), root.appending(path: "Studio Shoot"), root.appending(path: "Street")])
            let ready = await waitFor(timeout: 120) { Int(model.stats?.total ?? 0) >= expected && (model.progress?.mediaRemaining ?? 1) == 0 && !(model.progress?.scanning ?? true) }
            guard ready else { print("SELFTEST FAIL library never finished indexing"); await finish(1, model) }
        } catch {
            print("SELFTEST FAIL cannot build the test library: \(error)")
            await finish(1, model)
        }
        NSApp.activate()
        model.sidebar = .all
        model.viewMode = .grid
        await sleep(1.0)

        let checks: [Check] = [
            Check(name: "hover-scrub: real tiles show different frames across the width, cached lookup is instant") { try await hoverScrub(model) },
            Check(name: "hover-scrub: the filmstrip survives on disk and reloads") { try await filmstripFromDisk(model) },
            Check(name: "Quick Look: Space opens the panel on the selection with neighbours to step through") { try await quickLook(model) },
            Check(name: "drag out: tiles and rows carry the file as a copy, nothing else, and never change the original") { try await dragOut(model) },
            Check(name: "keyboard: grid keys rate, flag and open the Viewer; every action has a menu item") { try await keyboard(model) },
            Check(name: "viewer zoom: opening a tile flies its picture into the Viewer, which then shows fully, and no panel is left behind") { try await viewerZoom(model) },
            Check(name: "search page: ⌘F opens it with its field focused, results match the library search, ↓ Return Escape, scope and ⌘K work") { try await searchPage(model) },
            Check(name: "semantic search: real photos are found by their human captions through the real model, in the real app") { try await semanticSearch(model, root: root) },
            Check(name: "text in pictures: a slide, a label in small print and a plain picture are read by Vision, and search finds them by their words") { try await textInPictures(model, root: root) },
            Check(name: "model under load: queries and pictures from many tasks at once give finite, repeatable vectors and no crash") { try await modelUnderLoad(model, root: root) },
            Check(name: "copies by meaning (A2): altered copies of a photo look like it by meaning, different photos do not") { try await copiesByMeaning(model, root: root) },
            Check(name: "labels (C1, C2): what a picture shows and what kind of picture it is, from its description") { try await labelsMeasured(model, root: root) },
            Check(name: "video moments: a video of four scenes is described at its scene changes, each with its time") { try await videoScenes(model, root: root) },
            Check(name: "more like this and why this matched: photos like a photo come first, never itself; words and meaning are explained") { try await moreLikeThisAndWhy(model, root: root) },
            Check(name: "model download (network, opt-in): a wrong checksum installs nothing; the pinned model downloads, verifies, installs, is used, and is removed") { try await modelDownload(model) },
            Check(name: "undo: turning a folder off, and removing an exclusion, can be undone") { try await folderUndo(model) },
            Check(name: "missing files: deleted files are marked, moved files are relinked, only missing files can be removed") { try await missingRepair(model, root: root) },
            Check(name: "accessibility: every control in the window has a name VoiceOver can read") { try await accessibilityAudit(model) },
            Check(name: "drives: unplugging keeps files searchable and unmarked; replugging brings work back") { try await driveCycle(model, root: root) },
            Check(name: "duplicates: copies across two drives are found, Move to Trash moves exactly the confirmed file, Undo puts it back, a changed file is refused") { try await duplicatesCleanup(model, root: root) },
            Check(name: "moved folder (app open): the library follows it and keeps ratings and tags") { try await movedWhileOpen(model, root: root) },
            Check(name: "moved folder (app closed): relaunch follows it and keeps ratings and tags") { try await movedWhileClosed(model, root: root) },
        ]
        // SELFTEST_ONLY: one name, or several separated by "|" (tools/offline-check.sh).
        let only = ProcessInfo.processInfo.environment["SELFTEST_ONLY"]?.split(separator: "|").map(String.init)
        for check in checks where only == nil || (only ?? []).contains(where: { check.name.localizedCaseInsensitiveContains($0) }) {
            let started = ContinuousClock.now
            ran += 1
            do {
                let note = try await check.body()
                results.append((check.name, true, note))
                print("PASS  \(check.name)  (\(started.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))))\(note.isEmpty ? "" : "\n      \(note)")")
            } catch let skipped as Unverified {
                unverified += 1
                results.append((check.name, false, skipped.reason))
                print("UNVERIFIED  \(check.name)\n      \(skipped.reason)")
            } catch {
                failed += 1
                results.append((check.name, false, "\(error)"))
                print("FAIL  \(check.name)\n      \(error)")
            }
        }
        print("\nSELFTEST \(ran - failed - unverified) passed, \(failed) failed, \(unverified) unverified")
        await finish(failed == 0 ? 0 : 1, model)
    }

    /// Quits the way the app does (workers stopped, the model's running calls finished, the engine closed), then exits.
    /// A bare `exit` while the model was mid-evaluation crashed about one run in three.
    private static func finish(_ code: Int32, _ model: AppModel) async -> Never {
        await model.shutdown()
        exit(code)
    }

    // MARK: Hover-scrub (plan V2)

    private static func videoTile(in window: NSWindow) -> AssetTileView? {
        descendants(of: window.contentView?.superview ?? NSView(), as: AssetTileView.self).first { $0.summary?.kind == .video && $0.summary?.thumbRev ?? 0 > 0 }
    }

    private static func mouseMoved(on tile: AssetTileView, fraction: CGFloat) -> NSEvent? {
        guard let window = tile.window else { return nil }
        let inView = NSPoint(x: tile.imageView.frame.minX + tile.imageView.frame.width * fraction, y: tile.imageView.frame.midY)
        return NSEvent.mouseEvent(with: .mouseMoved, location: tile.convert(inView, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
    }

    /// The video whose tile the hover check used, so the next check looks at the same file.
    private nonisolated(unsafe) static var hoveredVideo: Int64?

    private static func hoverScrub(_ model: AppModel) async throws -> String {
        model.sidebar = .kind(.video)
        await sleep(1.5)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let tile = videoTile(in: window) else { throw Failure(description: "no video tile on screen") }
        guard let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil),
              let left = mouseMoved(on: tile, fraction: 0.04), let right = mouseMoved(on: tile, fraction: 0.96) else { throw Failure(description: "cannot make mouse events") }
        hoveredVideo = tile.summary?.id
        tile.mouseEntered(with: enter)
        // The first move starts making the filmstrip; keep hovering until frames from both ends are different pictures.
        let started = ContinuousClock.now
        var differs = false
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && !differs {
            tile.mouseMoved(with: left)
            let a = tile.imageView.image?.tiffRepresentation
            tile.mouseMoved(with: right)
            let b = tile.imageView.image?.tiffRepresentation
            differs = a != nil && b != nil && a != b
            if !differs { await sleep(0.25) }
        }
        try require(differs, "the first and last frames never differed: scrubbing did not show a filmstrip")
        let firstFrameAfter = started.duration(to: .now)

        // Cached: every move swaps in a frame. Plan target: under 50 ms per frame.
        let swaps = 200
        let t0 = ContinuousClock.now
        for i in 0..<swaps { tile.mouseMoved(with: i % 2 == 0 ? left : right) }
        let perMove = t0.duration(to: .now) / swaps
        let ms = Double(perMove.components.attoseconds) / 1e15
        try require(ms < 50, "a frame swap took \(ms) ms")
        let endFrame = tile.imageView.image
        tile.mouseExited(with: enter)
        try require(tile.imageView.image !== endFrame, "leaving the tile restores the poster frame")
        return String(format: "first frames after %.1f s (filmstrip made once); cached frame swap %.3f ms", Double(firstFrameAfter.components.seconds) + Double(firstFrameAfter.components.attoseconds) / 1e18, ms)
    }

    private static func filmstripFromDisk(_ model: AppModel) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        var q = SearchQuery.everything
        q.filters.kinds = [.video]
        let results = try await handle.search(query: q)
        // The video the hover check scrubbed (it made that filmstrip); the first video in the list if run alone.
        guard let id = hoveredVideo ?? results.idAt(index: 0), let summary = try await handle.summaries(assetIds: [id]).first else { throw Failure(description: "no video") }
        let strip = handle.filmstripPath(assetId: id, rev: summary.thumbRev)
        try require(FileManager.default.fileExists(atPath: strip), "no filmstrip file at \(strip)")
        let video = await model.paths(for: [id]).first
        let fresh = FilmstripStore()   // an empty cache, like a new launch
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<[CGImage]?, Never>) in
            var finished = false
            let first = fresh.frames(id: id, rev: summary.thumbRev, video: video, stripPath: strip) {
                if !finished { finished = true; continuation.resume(returning: fresh.frames(id: id, rev: summary.thumbRev, video: video, stripPath: strip) {}) }
            }
            if let first, !finished { finished = true; continuation.resume(returning: first) }
        }
        try require(loaded?.count == FilmstripStore.frameCount, "reloaded \(loaded?.count ?? 0) frames, expected \(FilmstripStore.frameCount)")
        let size = try FileManager.default.attributesOfItem(atPath: strip)[.size] as? Int ?? 0
        return "\(FilmstripStore.frameCount) frames from a \(size / 1000) KB strip file"
    }

    // MARK: Quick Look (plan V3)

    private static func quickLook(_ model: AppModel) async throws -> String {
        try await requireFrontmost()
        model.sidebar = .all
        await sleep(1.0)
        guard let results = model.results, let id = results.idAt(index: 5) else { throw Failure(description: "no results") }
        model.selectedIDs = [id]
        await QuickLookController.shared.show(model: model, ids: [id])
        await sleep(1.0)
        guard let panel = QLPreviewPanel.shared() else { throw Failure(description: "no Quick Look panel") }
        try require(panel.isVisible, "the panel did not open")
        let count = QuickLookController.shared.numberOfPreviewItems(in: panel)
        try require(count > 20, "only \(count) items to step through")
        try require(panel.currentPreviewItemIndex == 5, "started at item \(panel.currentPreviewItemIndex), not the selected one")
        let url = QuickLookController.shared.previewPanel(panel, previewItemAt: panel.currentPreviewItemIndex) as? URL
        let expected = await model.paths(for: [id]).first
        try require(url == expected, "the panel previews \(String(describing: url)), not the selected file")
        panel.close()
        await sleep(0.5)
        try require(!panel.isVisible, "the panel did not close")
        // Several files: preview just those.
        let several = Array((0..<3).compactMap { results.idAt(index: UInt64($0)) })
        await QuickLookController.shared.show(model: model, ids: several)
        await sleep(0.5)
        let n = QuickLookController.shared.numberOfPreviewItems(in: panel)
        panel.close()
        await sleep(0.3)
        try require(n == several.count, "a multi-selection previews \(n) items, expected \(several.count)")
        return "opens on the selection, \(count) files to arrow through; closes; multi-selection previews exactly the selected files"
    }

    // MARK: Drag out (plan W1, §3.2)

    private static func dragOut(_ model: AppModel) async throws -> String {
        try require(DragPolicy.toOtherApps == .copy, "other apps must only get a copy")
        try require(DragPolicy.withinApp.isEmpty, "files must not be draggable around inside the app")
        model.sidebar = .all
        model.viewMode = .grid
        await sleep(1.2)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let collection = descendants(of: window.contentView?.superview ?? NSView(), as: AssetCollectionView.self).first,
              let source = model.source,
              let coordinator = collection.delegate as? AssetGridView.Coordinator else { throw Failure(description: "no grid") }
        var checked = 0
        for index in [0, 7, 21] {
            guard let id = source.id(at: index) else { continue }
            _ = await model.paths(for: [id])
            source.ensure(index..<(index + 1))
            await sleep(0.4)
            guard let file = source.path(for: id) else { continue }
            let before = try Data(contentsOf: file)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let item = coordinator.collectionView(collection, pasteboardWriterForItemAt: IndexPath(item: index, section: 0)) as? NSPasteboardItem else {
                throw Failure(description: "no pasteboard item for \(file.lastPathComponent)")
            }
            try require(Set(item.types) == [.fileURL, .assetID], "the drag carries \(item.types.map(\.rawValue)); only a file URL and our id may travel")
            try require(item.string(forType: .fileURL) == file.absoluteString, "the file URL is not the original file")
            try require(URL(string: item.string(forType: .fileURL) ?? "")?.isFileURL == true, "not a file URL")
            // Reading the drag data must not have touched the original.
            let after = try Data(contentsOf: file)
            let attrsAfter = try FileManager.default.attributesOfItem(atPath: file.path)
            try require(before == after && attrs[.modificationDate] as? Date == attrsAfter[.modificationDate as FileAttributeKey] as? Date, "the original changed")
            checked += 1
        }
        try require(checked >= 2, "only \(checked) files could be checked")
        // The list view uses the same policy and the same writers.
        model.viewMode = .list
        await sleep(1.2)
        guard let table = descendants(of: window.contentView?.superview ?? NSView(), as: AssetTableView.self).first,
              let listCoordinator = table.delegate as? AssetListView.Coordinator else { throw Failure(description: "no list") }
        let writer = listCoordinator.tableView(table, pasteboardWriterForRow: 2) as? NSPasteboardItem
        try require(writer != nil && Set(writer!.types) == [.fileURL, .assetID], "the list's drag carries the wrong types")
        model.viewMode = .grid
        // An offline file offers nothing to drag, instead of a dead path.
        return "\(checked) tiles + 1 row: copy-only policy, file URL + id only, originals byte-identical"
    }

    // MARK: Keyboard (plan §12.3)

    private static func key(_ characters: String, code: UInt16, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    private static func allMenuTitles(_ menu: NSMenu?) -> [(title: String, enabled: Bool)] {
        var out: [(String, Bool)] = []
        for item in menu?.items ?? [] {
            if !item.isSeparatorItem { out.append((item.title, item.isEnabled)) }
            out += allMenuTitles(item.submenu).map { ($0.title, $0.enabled) }
        }
        return out
    }

    private static func keyboard(_ model: AppModel) async throws -> String {
        try await requireFrontmost()
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        model.sidebar = .all
        model.viewMode = .grid
        await sleep(1.2)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let collection = descendants(of: window.contentView?.superview ?? NSView(), as: AssetCollectionView.self).first,
              let coordinator = collection.delegate as? AssetGridView.Coordinator,
              let id = model.source?.id(at: 9) else { throw Failure(description: "no grid") }
        window.makeFirstResponder(collection)
        collection.selectionIndexPaths = [IndexPath(item: 9, section: 0)]
        coordinator.selectionChanged()
        func press(_ chars: String, _ code: UInt16) async throws {
            guard let event = key(chars, code: code, in: window) else { throw Failure(description: "cannot make a key event") }
            collection.keyDown(with: event)
            await sleep(0.6)
            // Undo groups close at the end of each real event. These keys are not delivered as events, so close the group
            // here; otherwise every key would pile into one group and a single undo would revert them all.
            if let undo = model.undoManager, undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
        for stars in 1...5 {
            try await press(String(stars), UInt16(17 + stars))
            let rating = try await handle.summaries(assetIds: [id]).first?.rating
            try require(rating == UInt8(stars), "pressing \(stars) gave rating \(String(describing: rating))")
        }
        try await press("0", 29)
        let cleared = try await handle.summaries(assetIds: [id]).first?.rating
        try require(cleared == 0, "pressing 0 did not clear the rating")
        try await press("p", 35)
        let picked = try await handle.summaries(assetIds: [id]).first?.flag
        try require(picked == .pick, "P did not pick")
        try await press("x", 7)
        let rejected = try await handle.summaries(assetIds: [id]).first?.flag
        try require(rejected == .reject, "X did not reject")
        try await press("u", 32)
        let none = try await handle.summaries(assetIds: [id]).first?.flag
        try require(none == Flag.none, "U did not clear the flag")
        // Undo (⌘Z) brings the previous value back.
        try await press("5", 23)
        model.undoManager?.undo()
        await sleep(0.8)
        let undone = try await handle.summaries(assetIds: [id]).first?.rating
        try require(undone == 0, "undo left rating \(String(describing: undone)))")
        // Return opens the Viewer window.
        try await press("\r", 36)
        await sleep(1.5)
        let viewer = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.lowercased().contains("viewer") == true }
        try require(viewer != nil, "Return did not open the Viewer")
        viewer?.close()
        await sleep(0.4)

        // Every action has a menu item (so it has a keyboard path), and selection-dependent ones follow the selection.
        let titles = allMenuTitles(NSApp.mainMenu)
        let required = ["Add Folder…", "New Collection…", "Open in Viewer", "Quick Look", "Show in Finder", "as Grid", "as List", "Make Thumbnails Larger",
                        "Make Thumbnails Smaller", "Sort By", "Pause Indexing", "Cancel Indexing", "Index Unfinished Files", "Rescan All Folders", "Show Missing Files",
                        "Rating", "Flag", "Color Label", "Add Tags…", "Add to Collection", "Show Inspector", "Show Sidebar"]
        let missing = required.filter { r in !titles.contains { $0.title == r || $0.title.hasPrefix(r) || ($0.title == "Hide Inspector" && r == "Show Inspector") || ($0.title == "Hide Sidebar" && r == "Show Sidebar") } }
        try require(missing.isEmpty, "no menu item for: \(missing.joined(separator: ", "))")
        return "keys 1–5, 0, P, X, U, Return and ⌘Z drive the real grid; \(required.count) actions all have menu items"
    }

    // MARK: Zoom into the Viewer

    private static func viewerZoom(_ model: AppModel) async throws -> String {
        try await requireFrontmost()
        model.sidebar = .all
        model.viewMode = .grid
        model.selectedIDs = []
        await sleep(1.2)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.identifier?.rawValue.lowercased().contains("main") == true })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let collection = descendants(of: window.contentView?.superview ?? NSView(), as: AssetCollectionView.self).first,
              let coordinator = collection.delegate as? AssetGridView.Coordinator else { throw Failure(description: "no grid") }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(collection)
        // The first tile that shows a real thumbnail (a damaged or unindexed file has nothing to fly).
        func tileWithPicture() -> IndexPath? {
            (0..<12).map { IndexPath(item: $0, section: 0) }.first { path in
                guard let tile = (collection.item(at: path) as? AssetItem)?.tile else { return false }
                return (tile.summary?.thumbRev ?? 0) > 0 && (tile.imageView.image?.size.width ?? 0) > 48
            }
        }
        let ready = await waitFor(timeout: 10) { tileWithPicture() != nil }
        guard ready, let path = tileWithPicture() else { throw Failure(description: "no tile among the first twelve showed a thumbnail") }
        collection.selectionIndexPaths = [path]
        coordinator.selectionChanged()
        func flying() -> Bool { NSApp.windows.contains { $0 is NSPanel && $0.contentView is PictureView && $0.isVisible } }
        guard let event = keyEvent("\r", code: 36, in: window) else { throw Failure(description: "cannot make a Return event") }
        collection.keyDown(with: event)
        let sawPanel = await waitFor(timeout: 2) { flying() }
        try require(sawPanel, "no zoom panel appeared when the tile opened")
        let viewer = NSApp.windows.first { $0.identifier?.rawValue.lowercased().contains("viewer") == true }
        try require(viewer != nil, "the Viewer did not open")
        let done = await waitFor(timeout: 4) { !flying() && (viewer?.alphaValue ?? 0) == 1 }
        try require(done, "the zoom did not finish (panel still there: \(flying()), Viewer alpha \(viewer?.alphaValue ?? -1))")
        viewer?.close()
        await sleep(0.4)
        // A second open of the same file (already open elsewhere) must not leave the Viewer hidden.
        collection.keyDown(with: event)
        await sleep(1.6)
        let again = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.lowercased().contains("viewer") == true }
        try require(again != nil && again?.alphaValue == 1 && !flying(), "reopening left the Viewer hidden or a panel behind")
        again?.close()
        await sleep(0.4)
        return "a panel carried the tile’s picture to the Viewer; the Viewer ended fully visible and the panel closed; reopening is clean"
    }

    // MARK: Search page (story S13)

    private static func keyEvent(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    private static func menuItem(_ title: String, key: String, in items: [NSMenuItem]) throws -> NSMenuItem {
        guard let item = items.first(where: { $0.title == title }) else { throw Failure(description: "no \(title) menu item") }
        try require(item.keyEquivalent == key && item.keyEquivalentModifierMask.contains(.command), "\(title) is not on ⌘\(key.uppercased())")
        try require(item.isEnabled, "\(title) is disabled")
        return item
    }

    private static func searchPage(_ model: AppModel) async throws -> String {
        try await requireFrontmost()
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        model.sidebar = .all
        model.clearFilters()
        model.selectedIDs = []
        await sleep(1.0)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.identifier?.rawValue.lowercased().contains("main") == true })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { throw Failure(description: "no window") }
        window.makeKeyAndOrderFront(nil)
        func fieldFocused() -> Bool { (window.firstResponder as? NSTextView)?.isFieldEditor == true }

        // ⌘F is on the menu and opens the Search page, with the cursor in its field and nothing else focused.
        let items = allMenuItems(NSApp.mainMenu)
        let search = try menuItem("Search", key: "f", in: items)
        if let menu = search.menu { menu.performActionForItem(at: menu.index(of: search)) }
        try require(model.sidebar == .search, "⌘F did not open the Search page")
        let focused = await waitFor(timeout: 3) { fieldFocused() }
        try require(focused, "the Search page opened without its field focused (first responder: \(String(describing: window.firstResponder)))")
        try require(!model.hasSearchWords && model.searchScope == .everywhere, "the page did not start clean")

        // Typing goes through the real field, so the real binding and the real search run.
        guard let editor = window.firstResponder as? NSTextView else { throw Failure(description: "no field editor") }
        editor.insertText("img", replacementRange: NSRange(location: NSNotFound, length: 0))
        var all = SearchQuery.everything
        all.text = "img"
        let expected = Int(try await handle.search(query: all).count())
        let meaning = model.searchReadiness == .ready
        let found = await waitFor(timeout: 5) { model.searchText == "img" && (meaning ? model.resultCount >= expected : model.resultCount == expected) && model.resultCount > 0 }
        try require(found, "typing \"img\" showed \(model.resultCount) files, the library search \(expected)")
        try require(fieldFocused(), "the field lost focus when the first letter was typed")
        try require(model.showsResults, "results did not take over the page")
        let gridShown = await waitFor(timeout: 3) { window.contentView?.firstDescendant(where: { $0 is AssetCollectionView }) != nil }
        try require(gridShown, "the results grid did not appear")

        // ↓ moves from the field into the results and selects the first file.
        let down = String(UnicodeScalar(NSDownArrowFunctionKey) ?? " ")
        guard let downEvent = keyEvent(down, code: 125, flags: [.numericPad, .function], in: window) else { throw Failure(description: "cannot make an arrow key event") }
        NSApp.sendEvent(downEvent)
        let entered = await waitFor(timeout: 3) { model.selectedIDs.count == 1 && !fieldFocused() }
        try require(entered, "↓ did not move into the results (selected \(model.selectedIDs.count), field focused: \(fieldFocused()), results \(model.resultCount), key window is the library window: \(NSApp.keyWindow === window), first responder \(String(describing: window.firstResponder.map { type(of: $0) })), app active: \(NSApp.isActive))")

        // Return opens the selected file in the Viewer, and remembers the search.
        guard let returnEvent = keyEvent("\r", code: 36, in: window) else { throw Failure(description: "cannot make a Return event") }
        // The key goes to whatever has focus, as the keyboard does: here the grid, as ↓ left it.
        window.firstResponder?.keyDown(with: returnEvent)
        await sleep(1.5)
        let viewer = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.lowercased().contains("viewer") == true }
        try require(viewer != nil, "Return did not open the Viewer (first responder: \(String(describing: window.firstResponder)), selected \(model.selectedIDs.count))")
        try require(model.recentSearches.items.first == "img", "the search was not remembered (\(model.recentSearches.items))")
        viewer?.close()
        await sleep(0.4)

        // Escape clears the words; the results go and the page invites a new search.
        window.makeKeyAndOrderFront(nil)
        model.openSearch()
        _ = await waitFor(timeout: 3) { fieldFocused() }
        guard let escape = keyEvent("\u{1B}", code: 53, in: window) else { throw Failure(description: "cannot make an Escape event") }
        NSApp.sendEvent(escape)
        let cleared = await waitFor(timeout: 3) { !model.hasSearchWords }
        try require(cleared, "Escape did not clear the words")

        // ⌘F on a folder's page searches inside it; ⌘K searches everywhere; leaving the page drops the words.
        guard let folder = model.folders.first else { throw Failure(description: "no folder") }
        model.sidebar = .folder(folder.id)
        await sleep(0.4)
        if let menu = search.menu { menu.performActionForItem(at: menu.index(of: search)) }
        try require(model.sidebar == .search && model.searchScope == .folder(folder.id), "⌘F on a folder page did not scope the search to it")
        model.searchText = "img"
        let narrowed = await waitFor(timeout: 5) { model.resultCount > 0 && model.resultCount <= max(expected, model.resultCount) }
        try require(narrowed, "a scoped search showed nothing")
        let scopedCount = model.resultCount
        let everywhere = try menuItem("Search Everywhere", key: "k", in: items)
        if let menu = everywhere.menu { menu.performActionForItem(at: menu.index(of: everywhere)) }
        try require(model.searchScope == .everywhere, "⌘K did not search everywhere")
        let widened = await waitFor(timeout: 5) { model.resultCount >= scopedCount }
        try require(widened, "searching everywhere found fewer files than inside one folder")
        model.sidebar = .all
        try require(!model.hasSearchWords, "words stayed behind on the library page")
        model.clearFilters()
        await sleep(0.5)
        return "⌘F opens Search with the field focused; “img” found \(model.resultCount >= 0 ? expected : 0) files, same as the library search; typing keeps focus; ↓ enters the results; Return opens the Viewer and remembers the search; Escape clears; ⌘F on a folder scopes to it, ⌘K searches everywhere; leaving drops the words"
    }

    private static func allMenuItems(_ menu: NSMenu?) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for item in menu?.items ?? [] {
            out.append(item)
            out += allMenuItems(item.submenu)
        }
        return out
    }

    // MARK: Search by meaning (Phase 4)

    /// Real photographs with human captions (COCO, from the Phase 3 data), the real model, the real pipeline. A query is a
    /// caption; the answer is correct when the photo it describes comes back. This is a **public-photo check that the
    /// pipeline works end to end**. It is not creator-media validation and sets no pass bar for release (ROADMAP Phase 3).
    private static func semanticSearch(_ model: AppModel, root: URL) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let coco = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/SmartAsset/phase3/data/coco")
        // 100 photos by default. SA_SEMANTIC_PHOTOS=5000 repeats the measurement at the scale of Phase 3's 5,000-photo set.
        let count = Int(ProcessInfo.processInfo.environment["SA_SEMANTIC_PHOTOS"] ?? "") ?? 100
        let big = count > 500
        let imageFolder = big ? "images5k" : "images500"
        guard let data = try? Data(contentsOf: coco.appending(path: big ? "captions5k.json" : "captions500.json")),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Unverified(reason: "the COCO captions are not at \(coco.path) (Phase 3 data)")
        }
        let loaded = await waitFor(timeout: 240) { model.semantic != .loading }
        guard loaded, model.semantic == .ready, model.embeddingModel != nil else {
            throw Unverified(reason: "the search model did not load (\(model.semantic))")
        }

        // 100 photographs into the test library.
        let photos = root.appending(path: "Photos")
        try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        var chosen: [(name: String, caption: String, all: [String])] = []
        for row in rows {
            guard chosen.count < count, let file = row["file"] as? String, let captions = row["captions"] as? [String], let caption = captions.first,
                  FileManager.default.fileExists(atPath: coco.appending(path: "\(imageFolder)/\(file)").path) else { continue }
            let target = photos.appending(path: file)
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: coco.appending(path: "\(imageFolder)/\(file)"), to: target) }
            chosen.append((file, caption, captions))
        }
        try require(chosen.count == count, "found only \(chosen.count) COCO images")
        await model.addFolders([photos])
        let started = ContinuousClock.now
        let indexed = await pollAsync(timeout: 600 + Double(count) * 0.5) {
            let p = model.progress
            guard (p?.mediaRemaining ?? 1) == 0, !(p?.scanning ?? true), (p?.embedRemaining ?? 1) == 0 else { return false }
            return ((try? await handle.embeddingStatus().withVectors) ?? 0) >= Int64(count)
        }
        let seconds = started.duration(to: .now).components.seconds
        let status = try await handle.embeddingStatus()
        try require(indexed, "the photos were not all embedded in time (vectors: \(status.withVectors), waiting: \(status.remaining))")

        // Which asset is which photo.
        var ids: [String: Int64] = [:]
        let everything = try await handle.search(query: .everything).allIds()
        for start in stride(from: 0, to: everything.count, by: 400) {
            for s in try await handle.summaries(assetIds: Array(everything[start..<min(everything.count, start + 400)])) { ids[s.name] = s.id }
        }

        var meaningRanks: [Int?] = []
        var wordRanks: [Int?] = []
        var spent = Duration.zero
        for (name, caption, _) in chosen {
            guard let id = ids[name] else { throw Failure(description: "\(name) is not in the library") }
            var q = SearchQuery.everything
            q.text = caption
            q.sort = Sort(key: .relevance, descending: false)
            let t0 = ContinuousClock.now
            let vector = await model.queryVector(caption)
            try require(!vector.isEmpty, "the model gave no vector for a query")
            let byMeaning = try await handle.searchHybrid(query: q, vector: vector).allIds()
            spent += t0.duration(to: .now)
            meaningRanks.append(byMeaning.firstIndex(of: id))
            wordRanks.append(try await handle.search(query: q).allIds().firstIndex(of: id))
        }

        // How similar is the right answer, and how similar is the best answer to a question the library cannot answer?
        // (Measured so the cut-offs in sa-engine come from data; see SEMANTIC_BAND and SEMANTIC_FLOOR.)
        func quantile(_ values: [Float], _ q: Double) -> Float {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
        }
        var topScores: [Float] = [], rightScores: [Float] = [], margins: [Float] = [], gaps: [Float] = [], topZ: [Float] = [], junkZ: [Float] = []
        for (name, _, captions) in chosen {
            guard let id = ids[name] else { continue }
            for caption in captions.prefix(big ? 2 : 5) {
                let answer = try await handle.semanticHits(vector: await model.queryVector(caption), limit: 50)
                let hits = answer.hits
                guard hits.count > 10, answer.std > 0 else { continue }
                topZ.append((hits[0].score - answer.mean) / answer.std)
                topScores.append(hits[0].score)
                margins.append(hits[0].score - hits[hits.count - 1].score)
                gaps.append(hits[0].score - hits[1].score)
                if let right = hits.first(where: { $0.assetId == id }) { rightScores.append(right.score) }
            }
        }
        let nonsense = ["zzzzqq", "asdkjh qwe", "xylophone quantum", "lorem ipsum dolor", "qqqq", "the", "blorp", "9482716", "hello", "kubernetes deployment yaml",
                        "invoice 2023", "meeting notes", "quarterly revenue", "password reset", "xkcd", "aaaa bbbb cccc", "oiuytrewq", "spreadsheet formula", "tax return", "zzz"]
        var junkTop: [Float] = [], junkMargin: [Float] = []
        for words in nonsense {
            let answer = try await handle.semanticHits(vector: await model.queryVector(words), limit: 50)
            let hits = answer.hits
            guard hits.count > 10, answer.std > 0 else { continue }
            junkZ.append((hits[0].score - answer.mean) / answer.std)
            junkTop.append(hits[0].score)
            junkMargin.append(hits[0].score - hits[hits.count - 1].score)
        }
        func line(_ v: [Float]) -> String { String(format: "min %.3f p5 %.3f p25 %.3f median %.3f p75 %.3f p95 %.3f max %.3f", quantile(v, 0), quantile(v, 0.05), quantile(v, 0.25), quantile(v, 0.5), quantile(v, 0.75), quantile(v, 0.95), quantile(v, 0.9999)) }
        print("SCORES captions top-1:        \(line(topScores))")
        print("SCORES captions right photo:  \(line(rightScores))")
        print("SCORES captions top1-top50:   \(line(margins))")
        print("SCORES captions top-1 z:      \(line(topZ))")
        print("SCORES nonsense top-1 z:      \(line(junkZ))")
        print("SCORES nonsense top-1:        \(line(junkTop))")
        print("SCORES nonsense top1-top50:   \(line(junkMargin))")

        // Short queries, the way people type them: one word, with the captions as ground truth (a photo is relevant when one of
        // its captions contains the word). How high does the best match score, and how wide a band below it is still relevant?
        var captionText: [Int64: String] = [:]
        for (name, _, captions) in chosen { if let id = ids[name] { captionText[id] = captions.joined(separator: " ").lowercased() } }
        let keywords = ["dog", "cat", "pizza", "giraffe", "train", "bus", "airplane", "bicycle", "surfboard", "umbrella", "clock", "bench", "elephant", "zebra",
                        "kitchen", "beach", "snow", "tennis", "baseball", "motorcycle", "sandwich", "bird", "boat", "horse", "truck", "laptop", "vase", "bear", "sheep", "skateboard"]
        var wordTop: [Float] = []
        let bands: [Float] = [0.02, 0.03, 0.05, 0.08, 0.12]
        var precision = [Double](repeating: 0, count: bands.count), recall = [Double](repeating: 0, count: bands.count), sizes = [Double](repeating: 0, count: bands.count)
        var used = 0
        for word in keywords {
            let relevant = Set(captionText.filter { $0.value.range(of: "\\b\(word)s?\\b", options: .regularExpression) != nil }.keys)
            guard relevant.count >= 5 else { continue }
            let answer = try await handle.semanticHits(vector: await model.queryVector(word), limit: 600)
            guard let top = answer.hits.first?.score else { continue }
            wordTop.append(top)
            used += 1
            for (i, band) in bands.enumerated() {
                let kept = answer.hits.filter { $0.score >= top - band }
                let good = kept.filter { relevant.contains($0.assetId) }.count
                precision[i] += Double(good) / Double(max(1, kept.count))
                recall[i] += Double(good) / Double(relevant.count)
                sizes[i] += Double(kept.count)
            }
        }
        print("SCORES one-word queries top-1 (\(used) words): \(line(wordTop))")
        for (i, band) in bands.enumerated() {
            print(String(format: "BAND within %.2f of the best: kept %.1f files on average, precision %.2f, recall %.2f", band, sizes[i] / Double(max(1, used)), precision[i] / Double(max(1, used)), recall[i] / Double(max(1, used))))
        }
        var oneWordJunk: [Float] = []
        for word in ["blorp", "zzzz", "qwerty", "asdf", "xylophone", "foobar", "lorem", "the", "and", "of", "invoice", "password", "spreadsheet", "meeting", "tax"] {
            if let top = try await handle.semanticHits(vector: await model.queryVector(word), limit: 5).hits.first?.score { oneWordJunk.append(top) }
        }
        print("SCORES one-word nonsense top-1:     \(line(oneWordJunk))")
        for cut in stride(from: Float(0.60), through: 0.74, by: 0.02) {
            func kept(_ v: [Float]) -> Int { Int((Double(v.filter { $0 >= cut }.count) / Double(max(1, v.count)) * 100).rounded()) }
            print(String(format: "CUT best match >= %.2f keeps: %d %% of captions, %d %% of one-word queries, %d %% of nonsense, %d %% of one-word nonsense", cut, kept(topScores), kept(wordTop), kept(junkTop), kept(oneWordJunk)))
        }

        // The calibration the model announces (minimum best match, band) is what keeps nonsense out and real questions in.
        // Checked through the real search, not through the scores: what a person would see.
        func answered(_ words: String) async throws -> Bool {
            var q = SearchQuery.everything
            q.text = words
            q.sort = Sort(key: .relevance, descending: false)
            let byMeaning = try await handle.searchHybrid(query: q, vector: await model.queryVector(words)).count()
            return byMeaning > (try await handle.search(query: q).count())
        }
        var junkAnswered = 0
        for words in nonsense where try await answered(words) { junkAnswered += 1 }
        // A word is only held to an answer when at least five photos' captions use it (the same rule as the measurement above).
        // Rarer words are reported: a photo that is the only one of its kind can score under the minimum for a one-word question.
        var oneWordMissed: [String] = []
        var rareAnswered: [String] = [], rareMissed: [String] = []
        for word in keywords {
            let matching = captionText.values.filter { $0.range(of: "\\b\(word)s?\\b", options: .regularExpression) != nil }.count
            guard matching > 0 else { continue }
            let ok = try await answered(word)
            if matching >= 5 { if !ok { oneWordMissed.append(word) } } else if ok { rareAnswered.append(word) } else { rareMissed.append("\(word) (\(matching))") }
        }
        let minimum = model.embeddingModel?.config.minMatch ?? 0
        let captionsKept = Double(topScores.filter { $0 >= minimum }.count) / Double(max(1, topScores.count))
        try require(junkAnswered <= nonsense.count / 10, "\(junkAnswered) of \(nonsense.count) nonsense questions were still answered by meaning")
        try require(oneWordMissed.isEmpty, "one-word questions with at least five matching photos got no answer by meaning: \(oneWordMissed.joined(separator: ", "))")
        try require(captionsKept >= 0.90, "only \(Int(captionsKept * 100)) % of the captions reach the model's minimum best match of \(minimum)")
        func rate(_ ranks: [Int?], _ k: Int) -> Double { Double(ranks.filter { ($0 ?? Int.max) < k }.count) / Double(ranks.count) }
        let (m1, m5, m10) = (rate(meaningRanks, 1), rate(meaningRanks, 5), rate(meaningRanks, 10))
        let (w1, w10) = (rate(wordRanks, 1), rate(wordRanks, 10))
        let perQuery = Double(spent.components.attoseconds) / 1e15 / Double(chosen.count) + Double(spent.components.seconds) * 1000 / Double(chosen.count)
        // A guard against a broken pipeline, not a quality bar: the same model scored 0.986 hit@10 on 500 images in Phase 3.
        try require(m10 >= 0.80, "by meaning, the right photo was in the first 10 for only \(Int(m10 * 100)) % of 100 captions (hit@1 \(m1), hit@5 \(m5))")
        try require(m10 > w10, "search by meaning (\(m10)) did no better than words alone (\(w10))")
        print(String(format: "GUARD nonsense answered by meaning: %d of %d; one-word questions (5+ photos) missed: %d; captions kept: %.0f %%", junkAnswered, nonsense.count, oneWordMissed.count, captionsKept * 100))
        print("GUARD rare one-word questions (1 to 4 photos): answered \(rareAnswered.count) of \(rareAnswered.count + rareMissed.count); not answered: \(rareMissed.joined(separator: ", "))")
        return String(format: "%d COCO photos embedded in %d s (about %d ms each incl. thumbnails). Caption → photo, library of %d files: by meaning hit@1 %.2f, hit@5 %.2f, hit@10 %.2f; words alone hit@1 %.2f, hit@10 %.2f; %.0f ms per question (query vector + blended search). Public photos, not creator media",
                      chosen.count, seconds, Int(Double(seconds) * 1000 / Double(chosen.count)), everything.count, m1, m5, m10, w1, w10, perQuery)
    }

    // MARK: Undo for folder changes

    private static func folderUndo(_ model: AppModel) async throws -> String {
        guard let handle = model.handle, let undo = model.undoManager else { throw Failure(description: "no engine or undo manager") }
        guard let folder = model.folders.first(where: { $0.displayName == "Iceland Trip" }) else { throw Failure(description: "no folder") }
        model.sidebar = .all
        let total = try await handle.search(query: .everything).count()
        await model.setFolderEnabled(folder.id, false)
        try require(model.folders.first { $0.id == folder.id }?.enabled == false, "the folder did not turn off")
        let hidden = try await handle.search(query: .everything).count()
        try require(hidden < total, "turning the folder off hid nothing (\(hidden) of \(total))")
        undo.undo()
        let backOn = await waitFor(timeout: 10) { model.folders.first { $0.id == folder.id }?.enabled == true }
        try require(backOn, "undo did not turn the folder back on")
        await sleep(1.0)
        let restored = try await handle.search(query: .everything).count()
        try require(restored == total, "after undo \(restored) files show, expected \(total)")

        // Excluding more is not undoable (it would not bring back ratings and tags); excluding less is.
        await model.setExcludes(folder.id, ["nothing-here"])
        undo.removeAllActions()
        await model.setExcludes(folder.id, [])
        undo.undo()
        let reExcluded = await waitFor(timeout: 10) { model.folders.first { $0.id == folder.id }?.excludes == ["nothing-here"] }
        try require(reExcluded, "undo did not restore the exclusion")
        await model.setExcludes(folder.id, [])
        return "off → \(hidden) of \(total) files shown → undo → all \(restored) back; exclusion removal undone"
    }

    // MARK: Missing files (plan H2)

    private static func missingRepair(_ model: AppModel, root: URL) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let base = root.deletingLastPathComponent().appending(path: "sa-missing")
        if FileManager.default.fileExists(atPath: base.path) { try FileManager.default.removeItem(at: base) }
        let a = base.appending(path: "A"), b = base.appending(path: "B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        // Unique pictures: copies of already-indexed files would be recognised as the same content (plan L3).
        for i in 0..<5 {
            try MediaFixtures.writeImage(MediaFixtures.bitmap(width: 700 + i * 37, height: 500 + i * 23), to: a.appending(path: "gap_\(i).jpg"), type: .jpeg)
        }
        await model.addFolders([a, b])
        let indexed = await waitFor(timeout: 60) { model.folders.first { $0.displayName == "A" }?.assetCount == 5 && (model.progress?.mediaRemaining ?? 1) == 0 }
        try require(indexed, "not indexed")
        var q = SearchQuery.everything
        q.text = "gap_"
        let ids = try await handle.search(query: q).allIds()
        try require(ids.count == 5, "found \(ids.count) of 5")
        let before = try await handle.stats().missing
        try await handle.setRating(assetIds: ids, rating: 4)

        // Two files are deleted, one is moved into the other added folder.
        let names = try await handle.summaries(assetIds: ids).map(\.name).sorted()
        try FileManager.default.removeItem(at: a.appending(path: names[0]))
        try FileManager.default.removeItem(at: a.appending(path: names[1]))
        try FileManager.default.moveItem(at: a.appending(path: names[2]), to: b.appending(path: names[2]))
        let marked = await waitFor(timeout: 40) { (model.stats?.missing ?? 0) == before + 2 }
        if !marked { try await handle.rescan(folderId: nil); await sleep(3) }
        let missingNow = try await handle.stats().missing
        let states = try await handle.summaries(assetIds: ids).map { "\($0.name)=\($0.missing ? "missing" : "present")" }.sorted().joined(separator: " ")
        let remaining = try await handle.search(query: q).count()
        try require(missingNow == before + 2, "expected 2 newly missing files; before=\(before) now=\(missingNow) tracked=\(ids.count) stillInLibrary=\(remaining) [\(states)] marked=\(marked)")
        let after = try await handle.summaries(assetIds: ids)
        let moved = after.first { $0.name == names[2] }
        try require(moved != nil && !moved!.missing && moved!.rating == 4, "the moved file was not relinked with its rating")
        try require(Set(after.filter(\.missing).map(\.name)) == Set([names[0], names[1]]), "the wrong files are missing")

        // Only missing files can be removed, whatever is asked.
        let removedPresent = try await handle.removeMissing(assetIds: after.filter { !$0.missing }.map(\.id))
        try require(removedPresent == 0, "a present file was removed")
        model.promptRemoveMissing(ids: nil)
        guard let removal = model.missingRemoval, removal.count >= 2 else { throw Failure(description: "the confirmation did not open (count \(model.missingRemoval?.count ?? -1))") }
        await model.removeMissing(removal)
        let left = try await handle.search(query: q).allIds()
        try require(left.count == 3, "\(left.count) files left in the library, expected 3")
        let missingEnd = try await handle.stats().missing
        try require(missingEnd == 0, "\(missingEnd) still missing")
        // The files on disk were never touched by removal.
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: a.path).count + FileManager.default.contentsOfDirectory(atPath: b.path).count
        try require(onDisk == 3, "\(onDisk) files on disk, expected the 3 that were not deleted")
        for folder in model.folders where ["A", "B"].contains(folder.displayName) { await model.removeFolder(folder.id) }
        return "2 deleted → marked missing, 1 moved → relinked with rating, removal took only the missing 2, disk untouched"
    }

    // MARK: Accessibility (VoiceOver names)

    /// One element of the accessibility tree as an assistive technology sees it.
    private struct AXNode: Sendable {
        var role: String
        var name: String
        var depth: Int
        var place: String = ""
    }

    /// Walks the real accessibility tree with the Accessibility API, the way VoiceOver does. SwiftUI only builds that tree
    /// when an assistive client is present, so this asks for it first, and runs the walk off the main thread (the app must be
    /// free to answer its own requests).
    private static func axTree() async -> (nodes: [AXNode], trusted: Bool) {
        await Task.detached(priority: .userInitiated) { () -> ([AXNode], Bool) in
            let app = AXUIElementCreateApplication(getpid())
            AXUIElementSetMessagingTimeout(app, 5)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            usleep(1_500_000)
            func string(_ e: AXUIElement, _ attr: String) -> String {
                var v: CFTypeRef?
                guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v else { return "" }
                if let s = v as? String { return s }
                if let n = v as? NSNumber { return n.stringValue }
                return ""
            }
            var out: [AXNode] = []
            func visit(_ e: AXUIElement, depth: Int) {
                guard depth < 30, out.count < 4000 else { return }
                let name = [string(e, "AXTitle"), string(e, "AXDescription"), string(e, "AXLabel"), string(e, "AXHelp"), string(e, "AXPlaceholderValue"), string(e, "AXValue"), string(e, "AXTitleUIElement")].first { !$0.isEmpty } ?? ""
                let subrole = string(e, "AXSubrole")
                // The window's own buttons and the scroll bars' arrows and pages are named by the system.
                let system: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
                                           "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]
                var place = ""
                var posRef: CFTypeRef?, sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, "AXPosition" as CFString, &posRef) == .success, let posRef,
                   AXUIElementCopyAttributeValue(e, "AXSize" as CFString, &sizeRef) == .success, let sizeRef {
                    var p = CGPoint.zero, sz = CGSize.zero
                    AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
                    AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz)
                    place = "at (\(Int(p.x)),\(Int(p.y))) \(Int(sz.width))×\(Int(sz.height)) id=\(string(e, "AXIdentifier")) sub=\(subrole)"
                }
                out.append(AXNode(role: system.contains(subrole) ? "AXSystem" : string(e, "AXRole"), name: name, depth: depth, place: place))
                var kids: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, "AXChildren" as CFString, &kids) == .success, let list = kids as? [AXUIElement] {
                    for k in list { visit(k, depth: depth + 1) }
                }
            }
            var windows: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &windows) == .success, let list = windows as? [AXUIElement] {
                for w in list { visit(w, depth: 0) }
            }
            return (out, AXIsProcessTrusted())
        }.value
    }

    private static func accessibilityAudit(_ model: AppModel) async throws -> String {
        model.viewMode = .grid
        model.sidebar = .all
        model.inspectorVisible = true
        await sleep(0.8)
        if let id = model.source?.id(at: 1) { model.selectedIDs = [id] }
        await sleep(1.2)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { throw Failure(description: "no window") }
        let (nodes, trusted) = await axTree()
        guard nodes.count > 40 else {
            throw Unverified(reason: "the accessibility tree was not exposed (\(nodes.count) elements; this process \(trusted ? "is" : "is not") trusted for Accessibility). Allow the terminal in System Settings ▸ Privacy & Security ▸ Accessibility, then run again.")
        }
        let interactive: Set<String> = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXTextField", "AXRadioButton", "AXComboBox", "AXDisclosureTriangle", "AXTextArea"]
        let unnamed = nodes.filter { interactive.contains($0.role) && $0.name.isEmpty }
        // The tiles: each one names its file, kind and state.
        let tiles = descendants(of: window.contentView?.superview ?? NSView(), as: AssetTileView.self)
        let tileProblems = tiles.filter { ($0.accessibilityLabel() ?? "").isEmpty || $0.accessibilityLabel() == "Loading" }
        try require(!tiles.isEmpty && tileProblems.isEmpty, "\(tileProblems.count) of \(tiles.count) tiles have no VoiceOver name")
        // Say where each one is: the nearest named element before it in the tree.
        var places: [String] = []
        for (i, node) in nodes.enumerated() where interactive.contains(node.role) && node.name.isEmpty {
            let before = nodes[..<i].reversed().first { !$0.name.isEmpty && $0.depth < node.depth }
            places.append("\(node.role) \(node.place) under “\(before?.name ?? "?")”")
        }
        try require(unnamed.isEmpty, "unnamed controls: " + places.joined(separator: "; "))
        let buttons = nodes.filter { interactive.contains($0.role) }.count
        return "\(nodes.count) accessibility elements walked via the Accessibility API, \(buttons) controls all named; \(tiles.count) tiles named"
    }

    // MARK: Drives (plan L4)

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func driveCycle(_ model: AppModel, root: URL) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let image = root.deletingLastPathComponent().appending(path: "sa-proof-disk")
        let imageFile = image.appendingPathExtension("sparseimage")
        let mount = "/Volumes/SAProofDisk"
        shell("/usr/bin/hdiutil", ["detach", mount, "-force"])
        if FileManager.default.fileExists(atPath: imageFile.path) { try FileManager.default.removeItem(at: imageFile) }
        let (c, out) = shell("/usr/bin/hdiutil", ["create", "-size", "96m", "-fs", "APFS", "-volname", "SAProofDisk", "-type", "SPARSE", image.path])
        try require(c == 0, "cannot create a disk image: \(out)")
        defer {
            shell("/usr/bin/hdiutil", ["detach", mount, "-force"])
            try? FileManager.default.removeItem(at: imageFile)
        }
        let (a, aout) = shell("/usr/bin/hdiutil", ["attach", imageFile.path])
        try require(a == 0, "cannot attach: \(aout)")
        let folder = URL(fileURLWithPath: "\(mount)/Shoot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sources = try FileManager.default.contentsOfDirectory(at: root.appending(path: "Iceland Trip"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }.prefix(12)
        for (i, src) in sources.enumerated() { try FileManager.default.copyItem(at: src, to: folder.appending(path: "drive_\(i).jpg")) }
        await model.addFolders([folder])
        let indexed = await waitFor(timeout: 60) { model.folders.first { $0.displayName == "Shoot" }?.assetCount == 12 && (model.progress?.mediaRemaining ?? 1) == 0 }
        try require(indexed, "the drive's files were not indexed")
        // Inside the drive's folder: elsewhere a photo of a road sign reads "SCENIC DRIVE" (text in pictures) and also matches.
        var q = SearchQuery.everything
        q.text = "drive_"
        if let shoot = model.folders.first(where: { $0.displayName == "Shoot" }) { q.filters.folderIds = [shoot.id] }
        let live = try await handle.search(query: q)
        let ids = live.allIds()
        try require(ids.count == 12, "found \(ids.count) of 12 drive files")
        try await handle.setRating(assetIds: [ids[0]], rating: 4)
        try await handle.addTags(assetIds: [ids[0]], names: ["on-the-drive"])
        let missingBefore = try await handle.stats().missing

        // Unplug.
        let (d, dout) = shell("/usr/bin/hdiutil", ["detach", mount])
        try require(d == 0, "cannot eject (the disk is busy?): \(dout)")
        let offline = await waitFor(timeout: 30) { model.folders.first { $0.displayName == "Shoot" }?.volumeOnline == false }
        try require(offline, "the app never noticed the drive was removed")
        let after = try await handle.search(query: q)
        try require(after.count() == 12, "while unplugged the search finds \(after.count()) of 12")
        let sums = try await handle.summaries(assetIds: ids)
        try require(sums.allSatisfy { !$0.volumeOnline && $0.volumeName == "SAProofDisk" && !$0.missing }, "files must be offline, name the drive, and not be missing")
        let paths = try await handle.paths(assetIds: ids)
        try require(paths.allSatisfy { $0.path == nil }, "an unplugged file must not have a path")
        try await handle.rescan(folderId: nil)
        await sleep(2.5)
        let stats = try await handle.stats()
        try require(stats.missing == missingBefore, "unplugging marked \(stats.missing - missingBefore) files missing")
        guard case .empty = try await handle.nextMediaBatch(maxItems: 5) else { throw Failure(description: "work was handed out for an unplugged drive") }

        // Plug back in.
        let (r, rout) = shell("/usr/bin/hdiutil", ["attach", imageFile.path])
        try require(r == 0, "cannot re-attach: \(rout)")
        let online = await waitFor(timeout: 30) { model.folders.first { $0.displayName == "Shoot" }?.volumeOnline == true }
        try require(online, "the app never noticed the drive came back")
        await sleep(2.5)
        let back = try await handle.summaries(assetIds: ids)
        try require(back.allSatisfy { $0.volumeOnline && !$0.missing }, "files did not come back online")
        try require(back[0].rating == 4, "the rating was lost")
        let detail = try await handle.assetDetail(assetId: ids[0])
        try require(detail.tags == ["on-the-drive"], "the tag was lost")
        let missingAfter = try await handle.stats().missing
        try require(missingAfter == missingBefore, "replugging left files missing")
        let pathBack = try await handle.paths(assetIds: [ids[0]]).first?.path
        try require(pathBack != nil, "the path did not come back")
        await model.removeFolder(model.folders.first { $0.displayName == "Shoot" }?.id ?? -1)
        return "12 files: offline = searchable, dimmed, named \"SAProofDisk\", 0 marked missing, no work leased; online = ratings, tags and paths back"
    }

    // MARK: Duplicates and cleanup (plan A1–A3)

    /// Bytes of a file, to prove an original is untouched.
    private static func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    private static func duplicatesCleanup(_ model: AppModel, root: URL) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let work = root.deletingLastPathComponent().appending(path: "sa-dups")
        let imageFile = root.deletingLastPathComponent().appending(path: "sa-dup-disk.sparseimage")
        let mount = "/Volumes/SADupDisk"
        shell("/usr/bin/hdiutil", ["detach", mount, "-force"])
        for url in [work, imageFile] where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let (c, out) = shell("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "APFS", "-volname", "SADupDisk", "-type", "SPARSE", imageFile.deletingPathExtension().path])
        try require(c == 0, "cannot create a disk image: \(out)")
        defer {
            shell("/usr/bin/hdiutil", ["detach", mount, "-force"])
            try? FileManager.default.removeItem(at: imageFile)
            try? FileManager.default.removeItem(at: work)
        }
        let (a, aout) = shell("/usr/bin/hdiutil", ["attach", imageFile.path])
        try require(a == 0, "cannot attach: \(aout)")

        // Two pictures on this Mac, and a copy of each on the other drive under another name.
        let local = work.appending(path: "Local"), disk = URL(fileURLWithPath: "\(mount)/Backup")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        for i in 0..<2 {
            try MediaFixtures.writeImage(MediaFixtures.bitmap(width: 900 + i * 61, height: 600 + i * 41), to: local.appending(path: "dup_\(i).jpg"), type: .jpeg)
            try FileManager.default.copyItem(at: local.appending(path: "dup_\(i).jpg"), to: disk.appending(path: "copy of dup_\(i).jpg"))
        }
        // Different pictures with the same size would be a trap for the cheap check; add one with its own content.
        try MediaFixtures.writeImage(MediaFixtures.bitmap(width: 780, height: 556), to: local.appending(path: "dup_solo.jpg"), type: .jpeg)
        let untouched: [URL] = [local.appending(path: "dup_0.jpg"), local.appending(path: "dup_1.jpg"), local.appending(path: "dup_solo.jpg"),
                                 disk.appending(path: "copy of dup_0.jpg"), disk.appending(path: "copy of dup_1.jpg")]
        let before = untouched.map { bytes($0) }

        await model.addFolders([local, disk])
        let indexed = await waitFor(timeout: 60) { model.folders.first { $0.displayName == "Local" }?.assetCount == 3 && model.folders.first { $0.displayName == "Backup" }?.assetCount == 2 && (model.progress?.mediaRemaining ?? 1) == 0 }
        try require(indexed, "the two folders were not indexed")
        var q = SearchQuery.everything
        q.text = "dup_"
        let ids = try await handle.search(query: q).allIds()
        /// Restored files come back as new records, so names are looked up again each time.
        func currentNames(_ d: DuplicatesDto) async -> [Int64: String] {
            let all = d.exact.flatMap { $0.members.map(\.assetId) }
            return Dictionary(uniqueKeysWithValues: ((try? await handle.summaries(assetIds: all)) ?? []).map { ($0.id, $0.name) })
        }
        /// The exact groups made of this test's files, with every member's current name.
        func ourGroups() async -> [(group: DuplicateGroupDto, names: [Int64: String])] {
            guard let d = try? await handle.duplicates() else { return [] }
            let n = await currentNames(d)
            return d.exact.filter { g in g.members.contains { (n[$0.assetId] ?? "").contains("dup_") } }.map { ($0, n) }
        }
        func group(containing name: String) async throws -> DuplicateGroupDto? {
            await ourGroups().first { entry in entry.group.members.contains { entry.names[$0.assetId] == name } }?.group
        }
        let found = await pollAsync(timeout: 60) {
            guard let d = try? await handle.duplicates(), d.hashRemaining == 0 else { return false }
            return await ourGroups().count == 2
        }
        try require(found, "the copies across the two drives were not found")
        let d = try await handle.duplicates()
        let mine = await ourGroups()
        try require(mine.allSatisfy { $0.group.members.count == 2 }, "each group must have exactly two copies")
        let solo = await currentNames(d)
        try require(!d.exact.contains { g in g.members.contains { solo[$0.assetId] == "dup_solo.jpg" } }, "a picture with no copy was grouped")

        // Work on the group of dup_0: the copy on the other drive goes to the Trash.
        guard let g0 = try await group(containing: "dup_0.jpg") else { throw Failure(description: "no group for dup_0") }
        let n0 = await currentNames(try await handle.duplicates())
        let copyOnDisk = g0.members.first { n0[$0.assetId] == "copy of dup_0.jpg" }?.assetId
        let original = g0.members.first { n0[$0.assetId] == "dup_0.jpg" }?.assetId
        guard let copyOnDisk, let original else { throw Failure(description: "the group does not hold both files") }
        try await handle.setRating(assetIds: [copyOnDisk], rating: 4)
        try await handle.addTags(assetIds: [copyOnDisk], names: ["from-backup"])

        model.sidebar = .duplicates
        model.refreshDuplicates()
        _ = await waitFor(timeout: 10) { model.duplicates?.exact.contains { $0.key == g0.key } == true }
        model.setTick(copyOnDisk, true, in: g0.key)
        await model.reviewCleanup(of: g0)
        guard let review = model.cleanupReview else { throw Failure(description: "the review did not open") }
        try require(review.remove.map(\.assetId) == [copyOnDisk] && review.keep.map(\.assetId) == [original], "the review lists the wrong files")
        try require(review.remove[0].path.hasPrefix(mount) && review.remove[0].size > 0 && review.remove[0].matchPercent == 100, "the review misses its details")
        try require(untouched.map { bytes($0) } == before, "reviewing changed a file")

        await model.confirmCleanup()
        try require(model.cleanupReview == nil, "the review stayed open: \(model.cleanupReview?.phase as Any)")
        guard let trash = model.lastTrash, trash.moved.count == 1 else { throw Failure(description: "nothing was recorded as trashed") }
        let trashed = trash.moved[0]
        try require(!FileManager.default.fileExists(atPath: trashed.original.path), "the file is still where it was")
        try require(FileManager.default.fileExists(atPath: trashed.trashed.path), "the file is not in the Trash at \(trashed.trashed.path)")
        try require(trashed.trashed.path.contains(".Trash"), "the file went somewhere that is not a Trash: \(trashed.trashed.path)")
        try require(bytes(trashed.trashed) == before[3], "the file in the Trash is not byte-identical")
        try require(bytes(untouched[0]) == before[0] && bytes(untouched[1]) == before[1] && bytes(untouched[2]) == before[2] && bytes(untouched[4]) == before[4], "another file changed")
        let left = try await handle.search(query: q).allIds()
        try require(left.count == ids.count - 1 && !left.contains(copyOnDisk), "exactly one record should have left the library (\(left.count) of \(ids.count))")
        let keeper = try await handle.assetDetail(assetId: original)
        try require(keeper.summary.rating == 4 && keeper.tags == ["from-backup"], "the rating and tag did not move to the copy that stays")

        // Undo puts it back, byte for byte, and the library finds it again.
        await model.undoLastTrash()
        try require(FileManager.default.fileExists(atPath: trashed.original.path) && bytes(trashed.original) == before[3], "Undo did not put the file back")
        let back = await pollAsync(timeout: 40) { ((try? await handle.search(query: q).count()) ?? 0) == UInt64(ids.count) }
        try require(back, "the restored file was not picked up again")

        // One review for several groups: "Select Extra Copies in All Groups", narrowed to this test's two groups.
        let regrouped = await pollAsync(timeout: 40) {
            guard let d = try? await handle.duplicates(), d.hashRemaining == 0 else { return false }
            let groups = await ourGroups()
            return groups.count == 2 && groups.allSatisfy { $0.group.members.count == 2 }
        }
        if !regrouped {
            let d = try await handle.duplicates()
            let p = await handle.progress()
            throw Failure(description: "the two groups did not re-form after Undo: hashRemaining \(d.hashRemaining), media remaining \(p.mediaRemaining), scanning \(p.scanning), exact groups \(d.exact.map { $0.members.map(\.assetId) })")
        }
        // The page shows what the engine says, not an older snapshot (restored files are new records).
        model.refreshDuplicates()
        let engineSets = Set(await ourGroups().map { Set($0.group.members.map(\.assetId)) })
        let pageCaughtUp = await pollAsync(timeout: 20) {
            let page = Set((model.duplicates?.exact ?? []).map { Set($0.members.map(\.assetId)) })
            return engineSets.isSubset(of: page)
        }
        try require(pageCaughtUp, "the Duplicates page never caught up with the engine")
        await model.selectExtraCopiesInAllGroups()
        let ours = Set(await ourGroups().map(\.group.key))
        try require(ours.count == 2, "expected two groups of this test, found \(ours.count)")
        model.dupTicks = model.dupTicks.filter { ours.contains($0.key) }
        let diag = await ourGroups().map { entry in entry.group.members.map { "\($0.assetId)\($0.suggestedKeep ? "*" : "")=\(entry.names[$0.assetId] ?? "?")" } }
        try require(model.tickedCount == 2, "members \(diag); Select Extra Copies ticked \(model.tickedCount) files, not one per group: ticks \(model.dupTicks.mapValues(\.count)), ours \(ours), groups \((model.duplicates?.exact ?? []).map { "\($0.key.prefix(6)):\($0.members.map(\.assetId))" })")
        await model.reviewTickedCopies()
        guard let bulk = model.cleanupReview, bulk.entries.count == 2, bulk.remove.count == 2, bulk.keep.count == 2 else {
            throw Failure(description: "the combined review is wrong: \(model.cleanupReview?.entries.count ?? -1) groups")
        }
        let bulkBefore = untouched.map { bytes($0) }
        await model.confirmCleanup()
        try require(model.cleanupReview == nil, "the combined review stayed open: \(String(describing: model.cleanupReview?.phase))")
        guard let both = model.lastTrash, both.moved.count == 2 else { throw Failure(description: "expected two files in the Trash, got \(model.lastTrash?.moved.count ?? 0)") }
        try require(both.moved.allSatisfy { FileManager.default.fileExists(atPath: $0.trashed.path) && !FileManager.default.fileExists(atPath: $0.original.path) }, "the files did not all move to the Trash")
        let survivors = untouched.filter { FileManager.default.fileExists(atPath: $0.path) }
        try require(survivors.count == 3 && survivors.contains(untouched[2]), "each group must keep exactly one copy, and the solo picture stays (\(survivors.count) files left)")
        await model.undoLastTrash()
        try require(untouched.map { bytes($0) } == bulkBefore, "Undo did not restore both files byte for byte")
        let backAgain = await pollAsync(timeout: 40) {
            guard let d = try? await handle.duplicates(), d.hashRemaining == 0 else { return false }
            let groups = await ourGroups()
            return groups.count == 2 && groups.allSatisfy { $0.group.members.count == 2 }
        }
        if !backAgain {
            let d = try await handle.duplicates()
            let p = await handle.progress()
            let present = untouched.map { FileManager.default.fileExists(atPath: $0.path) }
            throw Failure(description: "the groups did not re-form after the second Undo: hashRemaining \(d.hashRemaining), perceptualRemaining \(d.perceptualRemaining), media remaining \(p.mediaRemaining), scanning \(p.scanning), hold \(String(describing: p.hold)), exact groups \(d.exact.map { $0.members.map(\.assetId) }), files present \(present), records \(try await handle.search(query: q).count()) of \(ids.count)")
        }

        // A file that changes after the review is refused, and nothing moves.
        guard let g1 = try await group(containing: "dup_1.jpg") else { throw Failure(description: "no group for dup_1") }
        let n1 = await currentNames(try await handle.duplicates())
        guard let victim = g1.members.first(where: { n1[$0.assetId] == "copy of dup_1.jpg" })?.assetId else { throw Failure(description: "the copy of dup_1 is not in its group") }
        model.setTick(victim, true, in: g1.key)
        await model.reviewCleanup(of: g1)
        guard model.cleanupReview != nil else { throw Failure(description: "the second review did not open") }
        var edited = before[4] ?? Data()
        edited.append(contentsOf: [0, 1, 2, 3])
        try edited.write(to: untouched[4])
        await model.confirmCleanup()
        guard case .refused(let why)? = model.cleanupReview?.phase else { throw Failure(description: "a changed file was not refused (phase \(String(describing: model.cleanupReview?.phase)))") }
        try require(!why.contains("BridgeError") && why.contains("changed after it was scanned"), "the refusal is not a sentence a person can read: \(why)")
        try require(FileManager.default.fileExists(atPath: untouched[4].path), "a refused file still moved")
        try require(model.lastTrash == nil || model.lastTrash?.moved.first?.original != untouched[4], "a refused file was recorded as trashed")
        model.cleanupReview = nil
        model.sidebar = .all
        for f in model.folders where ["Local", "Backup"].contains(f.displayName) { await model.removeFolder(f.id) }
        return "2 groups across 2 drives, 0 false groups; real Trash on the disk image; one combined review moved one copy from each group and Undo restored both byte-identical; refused after an edit: “\(why.prefix(70))…”"
    }

    // MARK: Moved folders (plan H2)

    private static func makeTrip(_ root: URL, named name: String) throws -> URL {
        let dir = root.deletingLastPathComponent().appending(path: "sa-moves").appending(path: name)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sources = try FileManager.default.contentsOfDirectory(at: root.appending(path: "Street"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }.prefix(6)
        for (i, src) in sources.enumerated() { try FileManager.default.copyItem(at: src, to: dir.appending(path: "trip_\(i).jpg")) }
        return dir
    }

    private static func movedWhileOpen(_ model: AppModel, root: URL) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let trip = try makeTrip(root, named: "Open Trip")
        await model.addFolders([trip])
        let id = model.folders.first { $0.displayName == "Open Trip" }?.id
        try require(id != nil, "the folder was not added")
        let ok = await waitFor(timeout: 40) { model.folders.first { $0.id == id }?.assetCount == 6 && (model.progress?.mediaRemaining ?? 1) == 0 }
        try require(ok, "not indexed")
        var q = SearchQuery.everything
        q.text = "trip_"
        let ids = try await handle.search(query: q).allIds()
        try await handle.setRating(assetIds: [ids[0]], rating: 5)
        try await handle.addTags(assetIds: [ids[0]], names: ["moved-open"])

        let moved = trip.deletingLastPathComponent().appending(path: "Renamed While Open")
        if FileManager.default.fileExists(atPath: moved.path) { try FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: trip, to: moved)
        let followed = await waitFor(timeout: 40) { samePlace(model.folders.first { $0.id == id }?.path, moved.path) }
        let path = model.folders.first { $0.id == id }?.path ?? "none"
        try require(followed, "the library still points at \(path), not \(moved.path)")
        await sleep(2.5)
        let sums = try await handle.summaries(assetIds: ids)
        try require(sums.allSatisfy { !$0.missing }, "\(sums.filter(\.missing).count) files were marked missing after the move")
        try require(sums.contains { $0.rating == 5 }, "the rating was lost")
        let tagList = try await handle.tags()
        try require(tagList.contains { $0.name == "moved-open" && $0.assetCount == 1 }, "the tag was lost")
        let missingNow = try await handle.stats().missing
        try require(missingNow == 0, "files were left missing")
        let sameIDs = Set(try await handle.search(query: q).allIds())
        try require(sameIDs == Set(ids), "the files got new records instead of keeping theirs")
        await model.removeFolder(id ?? -1)
        return "moved \"Open Trip\" → \"Renamed While Open\" while running: same 6 records, rating and tag kept, 0 missing"
    }

    private static func movedWhileClosed(_ model: AppModel, root: URL) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let trip = try makeTrip(root, named: "Closed Trip")
        await model.addFolders([trip])
        let id = model.folders.first { $0.displayName == "Closed Trip" }?.id
        try require(id != nil, "the folder was not added")
        let ok = await waitFor(timeout: 40) { model.folders.first { $0.id == id }?.assetCount == 6 && (model.progress?.mediaRemaining ?? 1) == 0 }
        try require(ok, "not indexed")
        var q = SearchQuery.everything
        q.text = "trip_"
        let ids = try await handle.search(query: q).allIds()
        try await handle.setRating(assetIds: [ids[0]], rating: 3)
        await model.shutdown()   // the app is "closed"

        let moved = trip.deletingLastPathComponent().appending(path: "Renamed While Closed")
        if FileManager.default.fileExists(atPath: moved.path) { try FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: trip, to: moved)

        let relaunched = AppModel()
        await relaunched.launch()
        try require(relaunched.phase == .ready, "relaunch failed: \(relaunched.phase)")
        let followed = await waitFor(timeout: 40) { samePlace(relaunched.folders.first { $0.id == id }?.path, moved.path) }
        let path = relaunched.folders.first { $0.id == id }?.path ?? "none"
        try require(followed, "after relaunch the library still points at \(path)")
        await sleep(3)
        guard let h2 = relaunched.handle else { throw Failure(description: "no engine after relaunch") }
        let sums = try await h2.summaries(assetIds: ids)
        try require(sums.count == 6 && sums.allSatisfy { !$0.missing }, "files went missing after the relaunch")
        try require(sums.contains { $0.rating == 3 }, "the rating was lost")
        let missing2 = try await h2.stats().missing
        try require(missing2 == 0, "missing files after relaunch")
        await relaunched.shutdown()
        return "moved while closed, relaunched: the library followed the folder (bookmark), same records, rating kept, 0 missing"
    }

    // MARK: Helpers

    /// /tmp is a symlink to /private/tmp; both spellings are the same place.
    private static func samePlace(_ a: String?, _ b: String) -> Bool {
        func canon(_ p: String) -> String { p.hasPrefix("/private/") ? String(p.dropFirst(8)) : p }
        return a.map { canon($0) == canon(b) } ?? false
    }

    private static func descendants<V: NSView>(of view: NSView, as type: V.Type) -> [V] {
        var out: [V] = []
        if let v = view as? V { out.append(v) }
        for sub in view.subviews { out += descendants(of: sub, as: type) }
        return out
    }

    /// S4 through the real pipeline: pictures with known words are made, added, read by Vision in the real worker, and
    /// found by keyword search. A slide (large words), a shipping label in small print on a large picture (needs the
    /// original's pixels, not the 512 px thumbnail) and a picture with no words.
    private static func textInPictures(_ model: AppModel, root: URL) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let folder = root.appending(path: "Text")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try drawPicture(width: 1600, height: 900, lines: [("Quarterly Roadmap", 120), ("Planning review 2027", 64)], to: folder.appending(path: "slide.png"))
        try drawPicture(width: 3000, height: 2000, lines: [("Shipping label", 30), ("Tracking ZX4471 Harbourview depot", 30)], to: folder.appending(path: "label.png"))
        try drawPicture(width: 1200, height: 800, lines: [], to: folder.appending(path: "plain.png"))
        await model.addFolders([folder])
        // The library already holds other files in a full run, so wait for these three by name: first for them to be indexed,
        // then for each to have been read (a plain picture is read too, and has empty text).
        var ids: [String: Int64] = [:]
        let indexed = await pollAsync(timeout: 120) {
            guard let everything = try? await handle.search(query: .everything).allIds(),
                  let summaries = try? await handle.summaries(assetIds: everything) else { return false }
            for s in summaries where ["slide.png", "label.png", "plain.png"].contains(s.name) { ids[s.name] = s.id }
            return ids.count == 3
        }
        try require(indexed, "the generated pictures were not indexed in time (\(ids.keys.sorted()))")
        guard let slide = ids["slide.png"], let label = ids["label.png"], let plain = ids["plain.png"] else { throw Failure(description: "unreachable") }
        let read = await pollAsync(timeout: 240) {
            for id in [slide, label, plain] where (try? await handle.textOf(assetId: id)) == nil { return false }
            return true
        }
        let status = try await handle.textStatus()
        try require(read, "the pictures were not all read in time (read \(status.read), waiting \(status.remaining))")
        func found(_ words: String) async throws -> [Int64] {
            var q = SearchQuery.everything
            q.text = words
            q.sort = Sort(key: .relevance, descending: false)
            return try await handle.search(query: q).allIds()
        }
        let roadmap = try await found("roadmap")
        let title = try await found("quarterly roadmap")
        let code = try await found("ZX4471")
        let place = try await found("harbourview")
        let labelText = try await handle.textOf(assetId: label) ?? "not read"
        let plainText = try await handle.textOf(assetId: plain) ?? "not read"
        try require(roadmap.contains(slide), "the slide was not found by a word on it")
        try require(title.first == slide, "the slide is not first for its title")
        try require(code.contains(label), "the label's small print was not read (text: \(labelText))")
        try require(place.contains(label), "the label's place name was not found (text: \(labelText))")
        try require(plainText.isEmpty, "Vision read words in a picture that has none: \(plainText)")
        try require(!roadmap.contains(plain), "a picture without words was found by a word")
        return "3 pictures read by \(status.reader ?? "?"): slide and small print found by their words, plain picture has none. Videos not covered here"
    }

    /// A2 measured: 200 real photographs (Phase 2's labeled set) and 10 altered copies of each of the first 40, all described
    /// from a 512 px picture as the app does from its thumbnail. How close is a copy to its original by meaning, and how close
    /// does the closest *different* photo get? The cut-off that confirms a group of similar copies comes from these numbers.
    private static func copiesByMeaning(_ model: AppModel, root: URL) async throws -> String {
        let loaded = await waitFor(timeout: 240) { model.semantic != .loading }
        guard loaded, model.semantic == .ready, let gemma = model.embeddingModel else { throw Unverified(reason: "the search model did not load (\(model.semantic))") }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/SmartAsset/fixtures/photos")
        let photos = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.path < $1.path }
        guard photos.count >= 100 else { throw Unverified(reason: "the labeled photos are not at \(dir.path) (tools/fetch-photo-fixtures.sh)") }
        let work = root.appending(path: "copies-by-meaning")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        func thumbnailVector(_ image: CGImage, _ name: String, quality: Double = 0.85) async throws -> [Float] {
            let small = image.width > 512 || image.height > 512
                ? try PhotoVariants.scaled(image, width: image.width >= image.height ? 512 : max(1, image.width * 512 / image.height)) : image
            let file = work.appending(path: name + ".jpg")
            // The change is applied at full size (a re-encode at its quality), then reduced as the thumbnailer would.
            try PhotoVariants.writeJPEG(small, to: file, quality: quality)
            return try await gemma.embed(imageFile: file)
        }
        func cosine(_ a: [Float], _ b: [Float]) -> Float {
            let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            let n = (a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 }).squareRoot()
            return dot / max(n, 1e-9)
        }
        var originals: [[Float]] = []
        var images: [CGImage] = []
        for (i, url) in photos.prefix(200).enumerated() {
            guard let image = PhotoVariants.load(url) else { continue }
            if i < 40 { images.append(image) }
            originals.append(try await thumbnailVector(image, "o\(i)"))
        }
        var byChange: [String: [Float]] = [:]
        for (i, image) in images.enumerated() {
            for v in try PhotoVariants.variants(of: image) {
                // A re-encode is written at its own quality before the thumbnail is made from it.
                var source = v.image
                if v.quality < 0.85 {
                    let lossy = work.appending(path: "q\(i).jpg")
                    try PhotoVariants.writeJPEG(v.image, to: lossy, quality: v.quality)
                    source = PhotoVariants.load(lossy) ?? v.image
                }
                byChange[v.name, default: []].append(cosine(originals[i], try await thumbnailVector(source, "v\(i)")))
            }
        }
        var hardest: [Float] = []
        for i in originals.indices {
            hardest.append(originals.indices.filter { $0 != i }.map { cosine(originals[i], originals[$0]) }.max() ?? 0)
        }
        func q(_ v: [Float], _ p: Double) -> Float { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
        for name in byChange.keys.sorted() {
            let v = byChange[name] ?? []
            print(String(format: "COPIES %-14@ min %.3f p5 %.3f median %.3f", name as NSString, q(v, 0), q(v, 0.05), q(v, 0.5)))
        }
        print(String(format: "COPIES different photos, closest: median %.3f p95 %.3f p99 %.3f max %.3f (%d photos)", q(hardest, 0.5), q(hardest, 0.95), q(hardest, 0.99), q(hardest, 1), hardest.count))
        for cut in stride(from: Float(0.80), through: 0.96, by: 0.02) {
            let kept = byChange.filter { $0.key != "crop 20%" }.values.flatMap { $0 }
            let copies = Double(kept.filter { $0 >= cut }.count) / Double(max(1, kept.count))
            let crops = Double((byChange["crop 20%"] ?? []).filter { $0 >= cut }.count) / Double(max(1, byChange["crop 20%"]?.count ?? 1))
            let wrong = Double(hardest.filter { $0 >= cut }.count) / Double(max(1, hardest.count))
            print(String(format: "CUT %.2f keeps %.1f %% of copies (crop 20%%: %.0f %%), lets %.1f %% of different photos through", cut, copies * 100, crops * 100, wrong * 100))
        }
        guard let cut = model.embeddingModel?.config.copyMatch else { throw Unverified(reason: "this model announces no cut-off for copies") }
        let allCopies = byChange.values.flatMap { $0 }
        let kept = Double(allCopies.filter { $0 >= cut }.count) / Double(max(1, allCopies.count))
        let wrong = Double(hardest.filter { $0 >= cut }.count) / Double(max(1, hardest.count))
        try require(kept >= 0.98, "at the cut-off \(cut) only \(Int(kept * 100)) % of altered copies would stay in their group")
        try require(wrong <= 0.10, "at the cut-off \(cut), \(Int(wrong * 100)) % of the closest different photos would pass")
        return String(format: "%d photos, %d altered copies: at the cut-off %.2f, %.1f %% of copies stay; the closest different photo passes for %.1f %% (max %.3f). Real photos, not creator media",
                      originals.count, allCopies.count, cut, kept * 100, wrong * 100, q(hardest, 1))
    }

    /// H5 for real, against Hugging Face. Opt-in (`SA_NETWORK_TESTS=1`) and only into a test models folder in /tmp
    /// (`SA_MODELS_ROOT`), never the person's own. About 513 MB.
    private static func modelDownload(_ model: AppModel) async throws -> String {
        guard ProcessInfo.processInfo.environment["SA_NETWORK_TESTS"] == "1" else { throw Unverified(reason: "network tests are opt-in (SA_NETWORK_TESTS=1)") }
        let root = SemanticModels.modelsRoot.path
        guard ["/tmp/", "/private/tmp/"].contains(where: { root.hasPrefix($0) }) else { throw Failure(description: "SA_MODELS_ROOT must be a folder in /tmp, not \(root)") }
        let real = model.modelDownload
        // 1. A file whose pin does not match what Hugging Face serves: rejected, nothing installed.
        let pinned = real.model
        guard let small = pinned.files.first else { throw Failure(description: "no files") }
        let wrong = PinnedModel(id: "tamper", name: "Tamper test", publisher: pinned.publisher, repository: pinned.repository, commit: pinned.commit,
                                license: pinned.license, folder: "tamper",
                                files: [PinnedFile(path: small.path, bytes: small.bytes, sha256: String(repeating: "0", count: 64))])
        let tamper = ModelDownload(model: wrong)
        tamper.start()
        let refused = await waitFor(timeout: 120) { if case .failed = tamper.state { return true }; return false }
        try require(refused, "a file with a wrong checksum was not refused (state \(tamper.state))")
        if case .failed(let message) = tamper.state { try require(message.contains("checksum"), "the refusal does not say why: \(message)") }
        try require(!FileManager.default.fileExists(atPath: tamper.installFolder.path), "something was installed after a checksum mismatch")

        // 2. The pinned model, for real.
        try require(real.state == .notInstalled, "the test models folder already holds the model (state \(real.state))")
        let started = ContinuousClock.now
        real.start()
        let installed = await waitFor(timeout: 3600) { real.state == .installed || { if case .failed = real.state { return true }; return false }() }
        try require(installed && real.state == .installed, "the download did not finish: \(real.state)")
        let seconds = Double(started.duration(to: .now).components.seconds)
        try require(ModelFiles.isInstalled(real.model, in: real.installFolder), "the installed folder is not recognised")
        let problems = try ModelFiles.problems(real.model, in: real.installFolder)
        try require(problems.isEmpty, "an installed file does not match its pin: \(problems)")
        let ready = await waitFor(timeout: 240) { model.semantic == .ready }
        try require(ready, "search by meaning did not start with the downloaded model (\(model.semantic))")
        let vector = await model.queryVector("a dog on a beach")
        try require(vector.count == 768 && vector.allSatisfy(\.isFinite), "the downloaded model gives no usable vector")

        // 3. Remove: search by meaning stops, the files are gone, words keep working.
        await real.remove()
        try require(real.state == .notInstalled && !FileManager.default.fileExists(atPath: real.installFolder.path), "the model was not removed")
        try require(model.semantic != .ready && model.embeddingModel == nil, "search by meaning still runs after Remove")
        return String(format: "a wrong checksum was refused and nothing installed; 11 files (%@) downloaded from the pinned commit, verified and installed in %.0f s, used for a search, then removed", ModelDownload.size(real.model.totalBytes) as NSString, seconds)
    }

    /// The search model used the way the app uses it, all at once: questions typed while pictures are described, from tasks of
    /// several priorities. Reproduces the launch crashes of 8–9 Nov (MLX touched from many threads); every vector must be
    /// finite, and the same input must give the same vector whichever task asked.
    private static func modelUnderLoad(_ model: AppModel, root: URL) async throws -> String {
        let loaded = await waitFor(timeout: 240) { model.semantic != .loading }
        guard loaded, model.semantic == .ready, let gemma = model.embeddingModel else { throw Unverified(reason: "the search model did not load (\(model.semantic))") }
        let pictures = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
            .prefix(12)
        try require(pictures.count >= 6, "only \(pictures.count) pictures to describe")
        let questions = ["a dog on a beach", "street at night", "golden hour drone shot", "snow", "a red car", "people laughing"]
        let started = ContinuousClock.now
        let results: [(key: String, vector: [Float])] = try await withThrowingTaskGroup(of: [(String, [Float])].self) { group in
            for worker in 0..<8 {
                let priority: TaskPriority = [.background, .utility, .userInitiated, .high][worker % 4]
                group.addTask(priority: priority) {
                    var out: [(String, [Float])] = []
                    for round in 0..<40 {
                        if (round + worker) % 4 == 0 {
                            let picture = pictures[(round + worker) % pictures.count]
                            out.append(("picture:" + picture.lastPathComponent, try await gemma.embed(imageFile: picture)))
                        } else {
                            let question = questions[(round * 7 + worker) % questions.count]
                            out.append(("question:" + question, try await gemma.embed(query: question)))
                        }
                    }
                    return out
                }
            }
            var all: [(key: String, vector: [Float])] = []
            for try await part in group { all += part.map { (key: $0.0, vector: $0.1) } }
            return all
        }
        let seconds = Double(started.duration(to: .now).components.seconds)
        try require(results.count == 320, "only \(results.count) of 320 answers")
        try require(results.allSatisfy { !$0.vector.isEmpty && $0.vector.allSatisfy(\.isFinite) }, "a vector was empty or not finite")
        var first: [String: [Float]] = [:]
        var worst: Float = 1
        for r in results {
            guard let earlier = first[r.key] else { first[r.key] = r.vector; continue }
            let dot = zip(earlier, r.vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            let norms = (earlier.reduce(0) { $0 + $1 * $1 } * r.vector.reduce(0) { $0 + $1 * $1 }).squareRoot()
            worst = min(worst, dot / max(norms, 1e-9))
        }
        try require(worst > 0.999, "the same input gave different vectors (cosine \(worst))")
        return String(format: "320 answers (240 questions, 80 pictures) from 8 tasks of 4 priorities in %.0f s; all finite; same input, same vector (worst cosine %.5f)", seconds, worst)
    }

    /// S2 through the real pipeline: a 12 s video of four solid-colour scenes is described once per scene, with each scene's time.
    private static func videoScenes(_ model: AppModel, root: URL) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let loaded = await waitFor(timeout: 240) { model.semantic != .loading }
        guard loaded, model.semantic == .ready, model.embeddingModel != nil else { throw Unverified(reason: "the search model did not load (\(model.semantic))") }
        let folder = root.appending(path: "Scenes")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await MediaFixtures.sceneVideo(at: folder.appending(path: "four-scenes.mp4"),
                                           colors: [(200, 30, 30), (30, 200, 30), (30, 30, 200), (235, 235, 235)], secondsPerScene: 3)
        await model.addFolders([folder])
        // Wait for this video by name (a full run holds other files already), then for its vectors. The question is asked of
        // its folder alone, so the answer cannot depend on what else is in the library.
        var video: AssetSummaryDto?
        let indexed = await pollAsync(timeout: 120) {
            guard let everything = try? await handle.search(query: .everything).allIds(),
                  let summaries = try? await handle.summaries(assetIds: everything) else { return false }
            video = summaries.first { $0.name == "four-scenes.mp4" }
            return video != nil
        }
        guard indexed, let video else { throw Failure(description: "the generated video was not indexed in time") }
        let id = video.id
        let question = "a plain red screen"
        var asked = SearchQuery.everything
        asked.text = question
        asked.sort = Sort(key: .relevance, descending: false)
        asked.filters.folderIds = [video.folderId]
        let vector = await model.queryVector(question)
        var explanation: MatchExplanationDto?
        let described = await pollAsync(timeout: 240) {
            explanation = try? await handle.explainMatch(assetId: id, query: asked, vector: vector)
            return explanation?.meaning != nil
        }
        let vectorCount = (try? await handle.embeddingStatus().withVectors) ?? -1
        try require(described, "the video was not described in time (vectors in the library: \(vectorCount))")
        guard let meaning = explanation?.meaning else { throw Failure(description: "the video has no vectors") }
        try require(meaning.frames == 4, "expected one vector for each of the 4 scenes, got \(meaning.frames)")
        guard let moment = meaning.momentMs else { throw Failure(description: "the closest scene has no time") }
        // Scenes start at 0, 3, 6 and 9 s; the sampler looks at 0.5, 1.5, … s, so a scene is found at its first instant.
        let starts: [Int64] = [500, 3500, 6500, 9500]
        try require(starts.contains { abs($0 - moment) <= 600 }, "the moment \(moment) ms is not at a scene (0.5, 3.5, 6.5, 9.5 s)")
        // The Viewer opens the video at that moment when it is opened from a search.
        model.sidebar = .search
        model.searchScope = .folder(video.folderId)
        model.searchText = question
        let opened = await waitFor(timeout: 20) { !model.isSearching && model.resultCount > 0 }
        try require(opened, "the search found nothing")
        let viewer = ViewerModel(app: model)
        await viewer.show(id)
        try require(abs(viewer.startSeconds * 1000 - Double(moment)) < 1, "the Viewer would start at \(viewer.startSeconds) s, not \(Double(moment) / 1000) s")
        // The result's tile carries the same moment.
        if let index = model.results?.indexOf(id: id) { model.source?.ensure(Int(index)..<Int(index) + 1) }
        let tiled = await waitFor(timeout: 10) { model.source?.moment(for: id) != nil }
        try require(tiled && model.source?.moment(for: id) == moment, "the tile's moment is \(String(describing: model.source?.moment(for: id))), not \(moment)")
        // The Inspector lists the four scenes, and picking one opens the Viewer there.
        let scenes = try await handle.sceneTimes(assetId: id)
        try require(scenes.count == 4 && zip(scenes, starts).allSatisfy { abs($0 - $1) <= 600 }, "scenes at \(scenes) ms")
        model.viewerStart = (id, Double(scenes[2]) / 1000)
        await viewer.show(id)
        try require(abs(viewer.startSeconds - Double(scenes[2]) / 1000) < 0.001 && model.viewerStart == nil, "a picked moment did not open the Viewer there")
        model.searchText = ""
        model.searchScope = .everywhere
        return "4-scene video: 4 vectors; “\(question)” is closest at \(moment) ms (the red scene starts at 0); the Viewer, the tile and the Moments row agree. Generated clip, not creator media"
    }

    /// The first `count` photos of the Phase 3 COCO 500 set, added to the test library and described; with their five human
    /// captions (lower-cased, joined) as ground truth. Shared by the checks that measure search by meaning on real photos.
    private struct CocoLibrary {
        let chosen: [(name: String, captions: [String])]
        let ids: [String: Int64]
        let captionText: [Int64: String]
        let everything: [Int64]
    }

    private static func cocoLibrary(_ model: AppModel, root: URL, count: Int) async throws -> CocoLibrary {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let coco = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/SmartAsset/phase3/data/coco")
        guard let data = try? Data(contentsOf: coco.appending(path: "captions500.json")),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Unverified(reason: "the COCO captions are not at \(coco.path) (Phase 3 data)")
        }
        let loaded = await waitFor(timeout: 240) { model.semantic != .loading }
        guard loaded, model.semantic == .ready, model.embeddingModel != nil else { throw Unverified(reason: "the search model did not load (\(model.semantic))") }
        let photos = root.appending(path: "Photos")
        try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        var chosen: [(name: String, captions: [String])] = []
        for row in rows {
            guard chosen.count < count, let file = row["file"] as? String, let captions = row["captions"] as? [String],
                  FileManager.default.fileExists(atPath: coco.appending(path: "images500/\(file)").path) else { continue }
            let target = photos.appending(path: file)
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: coco.appending(path: "images500/\(file)"), to: target) }
            chosen.append((file, captions))
        }
        try require(chosen.count == count, "found only \(chosen.count) COCO images")
        await model.addFolders([photos])
        let indexed = await pollAsync(timeout: 600) {
            let p = model.progress
            guard (p?.mediaRemaining ?? 1) == 0, !(p?.scanning ?? true), (p?.embedRemaining ?? 1) == 0 else { return false }
            return ((try? await handle.embeddingStatus().withVectors) ?? 0) >= Int64(count)
        }
        try require(indexed, "the photos were not all described in time")
        var ids: [String: Int64] = [:]
        let everything = try await handle.search(query: .everything).allIds()
        for start in stride(from: 0, to: everything.count, by: 400) {
            for s in try await handle.summaries(assetIds: Array(everything[start..<min(everything.count, start + 400)])) { ids[s.name] = s.id }
        }
        // Ground truth for every COCO photo in the library, not only the ones this check added: an earlier check may have
        // added more, and an answer among those must not be counted wrong for want of captions.
        var captionText: [Int64: String] = [:]
        for row in rows {
            if let file = row["file"] as? String, let captions = row["captions"] as? [String], let id = ids[file] {
                captionText[id] = captions.joined(separator: " ").lowercased()
            }
        }
        return CocoLibrary(chosen: chosen, ids: ids, captionText: captionText, everything: everything)
    }

    /// C1 and C2 measured. C1: 30 object and scene words against 500 described COCO photos, ground truth = a caption uses the
    /// word. Two rules: an absolute cut-off, and the picture's 3 best labels that also pass it. C2: what kind of picture it is
    /// (photograph, screenshot, document, illustration) as the closest of four kind labels, on real photos and generated others.
    private static func labelsMeasured(_ model: AppModel, root: URL) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let count = Int(ProcessInfo.processInfo.environment["SA_LABEL_PHOTOS"] ?? "") ?? 500
        let library = try await cocoLibrary(model, root: root, count: count)
        guard let gemma = model.embeddingModel else { throw Unverified(reason: "no model") }
        let words = ["dog", "cat", "pizza", "giraffe", "train", "bus", "airplane", "bicycle", "surfboard", "umbrella", "clock", "bench", "elephant", "zebra",
                     "kitchen", "beach", "snow", "tennis", "baseball", "motorcycle", "sandwich", "bird", "boat", "horse", "truck", "laptop", "vase", "bear", "sheep", "skateboard"]
        let photoIDs = Set(library.captionText.keys)
        var score: [String: [Int64: Float]] = [:]
        for w in words {
            let answer = try await handle.semanticHits(vector: await model.queryVector(w), limit: UInt32(library.everything.count))
            score[w] = Dictionary(uniqueKeysWithValues: answer.hits.filter { photoIDs.contains($0.assetId) }.map { ($0.assetId, $0.score) })
        }
        func relevant(_ w: String, _ id: Int64) -> Bool {
            library.captionText[id]?.range(of: "\\b\(w)s?\\b", options: .regularExpression) != nil
        }
        for rule in ["absolute", "top 3"] {
            for cut in stride(from: Float(0.62), through: 0.76, by: 0.02) {
                var tp = 0, fp = 0, fn = 0
                for id in photoIDs {
                    let ranked = words.map { ($0, score[$0]?[id] ?? -1) }.sorted { $0.1 > $1.1 }
                    let given = Set((rule == "top 3" ? Array(ranked.prefix(3)) : ranked).filter { $0.1 >= cut }.map(\.0))
                    for w in words {
                        let r = relevant(w, id), g = given.contains(w)
                        if g && r { tp += 1 } else if g { fp += 1 } else if r { fn += 1 }
                    }
                }
                print(String(format: "LABELS %@ cut %.2f: precision %.2f recall %.2f (labels given %d)", rule, cut,
                             Double(tp) / Double(max(1, tp + fp)), Double(tp) / Double(max(1, tp + fn)), tp + fp))
            }
        }

        // C2: kinds of picture. Wordings are compared; the one the app uses is the first.
        let wordings: [[String]] = [
            ["a photo taken with a camera", "a screenshot of a computer screen", "a page of a text document", "a flat vector illustration"],
            ["a photograph", "a screenshot of an app", "a document page with text", "an illustration"],
            ["photo", "screenshot", "document", "drawing"],
        ]
        let dir = root.appending(path: "kinds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var samples: [(kind: Int, url: URL)] = []
        for i in 0..<12 {
            let shot = dir.appending(path: "screen\(i).png")
            try drawScreenshot(seed: i, to: shot)
            samples.append((1, shot))
            let doc = dir.appending(path: "doc\(i).png")
            try drawPicture(width: 1240, height: 1752, lines: (0..<28).map { ("Section \(i).\($0) The quarterly report covers revenue, costs and plans for the next year.", 26) }, to: doc)
            samples.append((2, doc))
            let art = dir.appending(path: "art\(i).png")
            try drawIllustration(seed: i, to: art)
            samples.append((3, art))
        }
        for name in library.chosen.prefix(60).map(\.name) { samples.append((0, root.appending(path: "Photos/\(name)"))) }
        var sampleVectors: [[Float]] = []
        for sample in samples { sampleVectors.append(try await gemma.embed(imageFile: sample.url)) }
        var right = 0
        for (w, kinds) in wordings.enumerated() {
            var kindVectors: [[Float]] = []
            for k in kinds { kindVectors.append(await model.queryVector(k)) }
            var confusion = Array(repeating: Array(repeating: 0, count: kinds.count), count: kinds.count)
            for (sample, v) in zip(samples, sampleVectors) {
                let best = kindVectors.indices.max { a, b in
                    zip(v, kindVectors[a]).reduce(0) { $0 + $1.0 * $1.1 } < zip(v, kindVectors[b]).reduce(0) { $0 + $1.0 * $1.1 }
                } ?? 0
                confusion[sample.kind][best] += 1
            }
            print("KINDS wording \(w): \(kinds.joined(separator: " | "))")
            for (i, row) in confusion.enumerated() { print("KINDS   \(kinds[i]) → \(row.map(String.init).joined(separator: " "))") }
            if w == 0 { right = kinds.indices.map { confusion[$0][$0] }.reduce(0, +) }
        }
        // End to end: the labels the Inspector would show, for the label words a caption can confirm.
        let checkable = Set(LabelWords.all).intersection(words)
        var given = 0, confirmed = 0
        for id in photoIDs {
            for label in try await handle.labelsOf(assetId: id) where checkable.contains(label.name) {
                given += 1
                if relevant(label.name, id) { confirmed += 1 }
            }
        }
        let precision = Double(confirmed) / Double(max(1, given))
        try require(given >= 50, "only \(given) labels were given for \(checkable.count) checkable words")
        try require(precision >= 0.75, "only \(Int(precision * 100)) % of the labels shown are confirmed by a caption")
        return String(format: "%d photos: %d labels shown for the %d label words a caption can confirm, %.0f %% confirmed (captions are incomplete, so this understates). Kinds of picture by the model: %d of %d right, too unreliable for photos against illustrations, so Content uses facts instead",
                      photoIDs.count, given, checkable.count, precision * 100, right, samples.count)
    }

    /// A made-up app window: a title bar, a sidebar, rows of text and a few buttons.
    private static func drawScreenshot(seed: Int, to url: URL) throws {
        let (w, h) = (1440, 900)
        let c = try PhotoVariants.context(width: w, height: h)
        c.setFillColor(gray: seed % 2 == 0 ? 0.97 : 0.15, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(gray: seed % 2 == 0 ? 0.88 : 0.22, alpha: 1); c.fill(CGRect(x: 0, y: h - 52, width: w, height: 52))
        c.setFillColor(gray: seed % 2 == 0 ? 0.92 : 0.19, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 260, height: h - 52))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        let ink = seed % 2 == 0 ? NSColor.black : NSColor.white
        for (n, title) in ["Inbox", "Projects", "Archive", "Settings", "Reports", "Shared"].enumerated() {
            NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: ink]).draw(at: CGPoint(x: 28, y: h - 110 - n * 44))
        }
        for row in 0..<14 {
            NSAttributedString(string: "Item \(row + seed * 3) — updated \(row + 2) minutes ago by Alex", attributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: ink])
                .draw(at: CGPoint(x: 300, y: h - 110 - row * 52))
        }
        NSGraphicsContext.restoreGraphicsState()
        c.setFillColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)
        c.fill(CGRect(x: w - 220, y: h - 44, width: 180, height: 32))
        guard let image = c.makeImage() else { throw Failure(description: "no screenshot") }
        try PhotoVariants.writeJPEG(image, to: url, quality: 0.9)
    }

    /// Flat shapes in a few colours, as a vector drawing would be.
    private static func drawIllustration(seed: Int, to url: URL) throws {
        let (w, h) = (1200, 900)
        let c = try PhotoVariants.context(width: w, height: h)
        var state = UInt64(seed + 1) &* 0x9E37_79B9_7F4A_7C15
        func next() -> CGFloat { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return CGFloat(state % 1000) / 1000 }
        c.setFillColor(red: next(), green: next(), blue: next(), alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for _ in 0..<9 {
            c.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
            let r = CGRect(x: next() * CGFloat(w), y: next() * CGFloat(h), width: 80 + next() * 400, height: 80 + next() * 400)
            if next() > 0.5 { c.fillEllipse(in: r) } else { c.fill(r) }
        }
        guard let image = c.makeImage() else { throw Failure(description: "no illustration") }
        try PhotoVariants.writeJPEG(image, to: url, quality: 0.9)
    }

    /// S7 and S11 on real photos. More Like This: for photos that a caption word describes, how many of the five closest files
    /// are described by the same word (against the share of the library the word describes). Then the interface: a file is
    /// never its own answer, typing words replaces it, and the explanation names where a word was found and how it looks.
    private static func moreLikeThisAndWhy(_ model: AppModel, root: URL) async throws -> String {
        guard let handle = model.handle else { throw Failure(description: "no engine") }
        let library = try await cocoLibrary(model, root: root, count: 100)
        let (chosen, ids, captionText, everything) = (library.chosen, library.ids, library.captionText, library.everything)
        let total = Double(captionText.count)

        // Measured: photos of a kind (a caption word) find other photos of the same kind.
        let keywords = ["dog", "cat", "pizza", "giraffe", "train", "bus", "airplane", "bicycle", "surfboard", "umbrella", "clock", "bench", "elephant", "zebra",
                        "kitchen", "beach", "snow", "tennis", "baseball", "motorcycle", "sandwich", "bird", "boat", "horse", "truck", "laptop", "vase", "bear", "sheep", "skateboard"]
        var precision: [Double] = [], baseline: [Double] = [], firstRight = 0, asked = 0, listLength: [Int] = []
        for word in keywords {
            let relevant = Set(captionText.filter { $0.value.range(of: "\\b\(word)s?\\b", options: .regularExpression) != nil }.keys)
            guard relevant.count >= 3 else { continue }
            for id in relevant.sorted().prefix(3) {
                guard let set = try await handle.searchSimilar(assetId: id, query: .everything) else { throw Failure(description: "a described photo has no answer") }
                let top = try await set.allIds()
                try require(!top.contains(id), "a file was its own answer")
                listLength.append(top.count)
                // As many answers as there are other photos of the kind, at most five, so a kind of three can still score 1.
                let k = min(5, relevant.count - 1)
                precision.append(Double(top.prefix(k).filter { relevant.contains($0) }.count) / Double(k))
                baseline.append(Double(relevant.count - 1) / (total - 1))
                if let first = top.first, relevant.contains(first) { firstRight += 1 }
                asked += 1
            }
        }
        try require(asked >= 12, "only \(asked) photos could be asked")
        let meanPrecision = precision.reduce(0, +) / Double(precision.count)
        let meanBaseline = baseline.reduce(0, +) / Double(baseline.count)
        // A guard against a broken pipeline, not a quality bar.
        try require(meanPrecision > 2 * meanBaseline, "More Like This is barely better than chance: precision@5 \(meanPrecision) against \(meanBaseline)")

        // The interface.
        model.sidebar = .search
        model.searchText = ""
        let sample = chosen[3]
        guard let sampleID = ids[sample.name] else { throw Failure(description: "\(sample.name) is not in the library") }
        await model.moreLikeThis(sampleID)
        let shown = await waitFor(timeout: 30) { model.searchLike?.id == sampleID && !model.isSearching && model.resultCount > 0 }
        try require(shown, "More Like This showed nothing")
        try require(model.sidebar == .search && model.searchHasQuestion && model.showsResults, "the Search page is not showing the results")
        try require(model.results?.indexOf(id: sampleID) == nil, "the file is in its own results")
        try require(model.resultCount >= 50, "only \(model.resultCount) files like it")
        model.searchText = "dog"
        try require(model.searchLike == nil, "typing words did not replace More Like This")
        model.clearLike()
        try require(model.searchLike == nil, "clearLike did not end More Like This")

        // Why this matched. Ten photos asked for by their own caption: search by meaning adds nearly all of them (the others have a
        // best match under the model's minimum and are found by words only, which has nothing to explain), and every one says so
        // in the same terms. A caption is in no name, tag or note, so no word is placed.
        let minimum = model.embeddingModel?.config.minMatch ?? 0
        var added: [(id: Int64, caption: String, score: Float)] = []
        for (name, captions) in chosen.prefix(10) {
            guard let id = ids[name] else { continue }
            var ownQuery = SearchQuery.everything
            ownQuery.text = captions[0]
            ownQuery.sort = Sort(key: .relevance, descending: false)
            let own = try await handle.explainMatch(assetId: id, query: ownQuery, vector: await model.queryVector(captions[0]))
            try require(own.words.isEmpty, "a caption is in no name, tag or note, yet words were placed for \(name): \(own.words.map(\.word))")
            if let m = own.meaning {
                try require(m.strong == (m.score >= minimum), "strong (\(m.strong)) disagrees with the score \(m.score) against the minimum \(minimum) for \(name)")
                try require(m.momentMs == nil, "a picture has no moment")
                added.append((id, captions[0], m.score))
            }
        }
        try require(added.count >= 7, "search by meaning added only \(added.count) of 10 photos for their own captions")
        // The same through the interface: the Search page's words, then the explanation for the selected file.
        guard let pick = added.first else { throw Failure(description: "no photo was added by meaning") }
        model.searchText = pick.caption
        let ranked = await waitFor(timeout: 30) { !model.isSearching && model.resultCount > 0 }
        try require(ranked, "the caption found nothing")
        guard let meaning = await model.explainMatch(pick.id)?.meaning else { throw Failure(description: "no explanation by meaning through the interface") }
        try require(abs(meaning.score - pick.score) < 0.001, "the interface and the engine disagree: \(meaning.score) and \(pick.score)")
        model.searchText = "val2014"
        let named = await waitFor(timeout: 30) { !model.isSearching && model.resultCount > 0 }
        try require(named, "the file name part found nothing")
        let byName = await model.explainMatch(sampleID)
        try require(byName?.words.first?.place == .name, "the word of the file name was not placed in the name: \(String(describing: byName?.words))")
        try require(byName?.meaning == nil, "a file-name word is not a question the library answers by meaning, yet a meaning match was explained: \(String(describing: byName?.meaning))")
        model.searchText = ""
        return String(format: "%d photos asked, %d COCO photos in the library: precision@k (k = 5 or the other photos of the kind) %.2f against %.2f for chance (%.1f×), first answer right %.0f %%; a file is never its own answer, typing replaces it; the explanation places name words and scores meaning (%d of 10 own captions added by meaning). Public photos, not creator media",
                      asked, captionText.count, meanPrecision, meanBaseline, meanPrecision / max(meanBaseline, 1e-9), Double(firstRight) / Double(asked) * 100, added.count)
    }

    /// A white picture with black lines of text (size in points), drawn with the system font, written as PNG.
    private static func drawPicture(width: Int, height: Int, lines: [(String, CGFloat)], to url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(description: "no drawing context") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        var y = CGFloat(height) * 0.7
        for (text, size) in lines {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.black]
            NSAttributedString(string: text, attributes: attributes).draw(at: CGPoint(x: CGFloat(width) * 0.08, y: y))
            y -= size * 1.6
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw Failure(description: "cannot write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "cannot write \(url.lastPathComponent)") }
    }

    /// Keys, focus and panels only reach an app that is in front. While the person uses another app, macOS may refuse to bring
    /// this one forward; the check then cannot run here, which is UNVERIFIED (run again when the Mac is idle), not a failure.
    private static func requireFrontmost() async throws {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.identifier?.rawValue.lowercased().contains("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        }
        let front = await waitFor(timeout: 3) { NSApp.isActive && NSApp.keyWindow != nil }
        guard front else { throw Unverified(reason: "another app is in front and macOS kept SmartAsset in the background; run again when the Mac is idle") }
    }

    /// Like `waitFor`, for a condition that has to ask the engine.
    private static func pollAsync(timeout: Double, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await condition()
    }

    private static func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func waitFor(timeout: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return condition()
    }
}
