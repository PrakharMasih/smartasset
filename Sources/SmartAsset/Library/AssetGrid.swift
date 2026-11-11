// The thumbnail grid (plan V1–V3): NSCollectionView over a paged, virtual result set.
// Only the tiles on screen exist, so 250,000 files scroll like 25.
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI

/// What a drag out of the library may do (plan §3.2): other apps get a copy; nothing can move or trash an original,
/// and files cannot be rearranged by dragging inside SmartAsset.
enum DragPolicy {
    static let toOtherApps: NSDragOperation = .copy
    static let withinApp: NSDragOperation = []
}

extension NSPasteboard.PasteboardType {
    /// Lets the sidebar know which files a drag carries, besides the file URLs other apps read.
    static let assetID = NSPasteboard.PasteboardType("com.smartasset.asset-id")
}

final class AssetCollectionView: NSCollectionView {
    weak var coordinator: AssetGridView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty, let coordinator, let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }
        switch key {
        case " ": coordinator.quickLook()
        case "\r": coordinator.openViewer()
        case "0", "1", "2", "3", "4", "5": coordinator.rate(UInt8(key) ?? 0)
        case "p": coordinator.flag(.pick)
        case "x": coordinator.flag(.reject)
        case "u": coordinator.flag(.none)
        case "\u{7F}": coordinator.removeFromCollection()
        default: super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        coordinator?.selectAll()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = indexPathForItem(at: point) else { return nil }
        if !selectionIndexPaths.contains(index) {
            selectionIndexPaths = [index]
            coordinator?.selectionChanged()
        }
        return coordinator?.contextMenu()
    }
}

struct AssetGridView: NSViewRepresentable {
    var model: AppModel
    var source: PagedSource?
    var generation: Int
    var thumbSize: Double
    var thumbsGeneration: Int
    var showNames: Bool
    var crop: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Metrics.cellGap
        layout.minimumLineSpacing = Metrics.cellGap
        layout.sectionInset = NSEdgeInsets(top: Space.xs, left: Space.xs, bottom: Space.xs, right: Space.xs)

        let collection = AssetCollectionView()
        collection.coordinator = coordinator
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(AssetItem.self, forItemWithIdentifier: Coordinator.itemID)
        collection.dataSource = coordinator
        collection.delegate = coordinator
        // Dragging out copies the original; nothing a drag does can move or trash a file (plan §3.2).
        collection.setDraggingSourceOperationMask(DragPolicy.toOtherApps, forLocal: false)
        collection.setDraggingSourceOperationMask(DragPolicy.withinApp, forLocal: true)
        collection.setAccessibilityLabel("Files")

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.attach(collection: collection, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(source: source, generation: generation, thumbSize: thumbSize, thumbsGeneration: thumbsGeneration, showNames: showNames, crop: crop)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        static let itemID = NSUserInterfaceItemIdentifier("asset")
        static let nameHeight: CGFloat = 20

        let model: AppModel
        private(set) var source: PagedSource?
        private weak var collection: AssetCollectionView?
        private weak var scroll: NSScrollView?
        private var generation = -1
        private var thumbSize: Double = 0
        private var thumbsGeneration = -1
        private var applyingSelection = false
        private let observers = ObserverBag()
        private var prioritizeTask: Task<Void, Never>?

        init(model: AppModel) { self.model = model }

        func attach(collection: AssetCollectionView, scroll: NSScrollView) {
            self.collection = collection
            self.scroll = scroll
            let center = NotificationCenter.default
            observers.add(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.widthChanged(); self?.visibleChanged() }
            })
            // A resize changes the scroll view's frame; the clip view's bounds notification does not reliably follow.
            scroll.postsFrameChangedNotifications = true
            observers.add(center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.widthChanged() }
            })
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                // Cheap enough to run for any window: it only restyles the visible tiles.
                observers.add(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshWindowState() }
                })
            }
        }

        // MARK: Updating from SwiftUI

        func update(source newSource: PagedSource?, generation newGeneration: Int, thumbSize newSize: Double, thumbsGeneration newThumbs: Int, showNames newShow: Bool, crop newCrop: Bool) {
            guard let collection else { return }
            var needsLayout = false
            if newCrop != cropped {
                cropped = newCrop
                for item in collection.visibleItems() { (item as? AssetItem)?.tile.fillsSquare = newCrop }
            }
            if newShow != namesShown {
                namesShown = newShow
                applyItemSize(to: collection)
                for item in collection.visibleItems() { (item as? AssetItem)?.tile.showsName = showsNames }
                needsLayout = true
            }
            if newSize != thumbSize {
                let anchor = topVisibleIndex()
                thumbSize = newSize
                applyItemSize(to: collection)
                needsLayout = true
                if let anchor { collection.scrollToItems(at: [IndexPath(item: anchor, section: 0)], scrollPosition: .top) }
            }
            if newGeneration != generation {
                let anchorID = topVisibleIndex().flatMap { source?.id(at: $0) }
                generation = newGeneration
                source?.onLoaded = nil
                source = newSource
                source?.onLoaded = { [weak self] range in self?.pageLoaded(range) }
                collection.reloadData()
                restoreScroll(toAssetID: anchorID)
                applySelectionFromModel()
                visibleChanged()
            } else if needsLayout {
                collection.collectionViewLayout?.invalidateLayout()
                visibleChanged()
            } else {
                applySelectionFromModel()
            }
            if newThumbs != thumbsGeneration {
                thumbsGeneration = newThumbs
                if let range = visibleRange() { source?.refresh(range) }
            }
            widthChanged()
        }

        /// Whole columns that fill the row exactly, each at least as wide as the chosen size: the gaps between pictures are
        /// then the same across and down, like a gallery, instead of the leftover width piling up between columns.
        private func applyItemSize(to collection: NSCollectionView) {
            guard let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            let target = CGFloat(thumbSize)
            let available = (scroll?.contentView.bounds.width ?? 0) - layout.sectionInset.left - layout.sectionInset.right
            let columns = max(1, (available / target).rounded(.down))
            let width = available > target ? (available / columns).rounded(.down) : target
            layout.itemSize = NSSize(width: width, height: width + (showsNames ? Self.nameHeight : 0))
        }

        private var lastWidth: CGFloat = 0

        /// The window was resized: fit the columns to the new width.
        private func widthChanged() {
            guard let collection, let scroll, abs(scroll.contentView.bounds.width - lastWidth) >= 1 else { return }
            lastWidth = scroll.contentView.bounds.width
            applyItemSize(to: collection)
            collection.collectionViewLayout?.invalidateLayout()
            visibleChanged()
        }

        /// Names are off unless View ▸ Show File Names is on, and only where the tile is wide enough to hold one.
        private var namesShown = false
        private var cropped = true
        private var showsNames: Bool { namesShown && thumbSize >= 120 }

        private func restoreScroll(toAssetID id: Int64?) {
            guard let collection, let id, let source, let index = source.results.indexOf(id: id) else { return }
            collection.scrollToItems(at: [IndexPath(item: Int(index), section: 0)], scrollPosition: .top)
        }

        // MARK: Data source

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { source?.count ?? 0 }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! AssetItem
            let tile = item.tile
            tile.showsName = showsNames
            tile.fillsSquare = cropped
            tile.windowIsActive = collectionView.window?.isKeyWindow ?? true
            tile.videoURL = { [weak self] id in self?.source?.path(for: id) }
            tile.stripPath = { [weak self] id, rev in self?.model.handle?.filmstripPath(assetId: id, rev: rev) ?? "" }
            tile.isSelectedTile = collectionView.selectionIndexPaths.contains(indexPath)
            configure(item, at: indexPath.item)
            source?.ensure(indexPath.item..<(indexPath.item + 1))
            return item
        }

        private func configure(_ item: AssetItem, at index: Int) {
            let summary = source?.summary(at: index)
            let scale = collection?.window?.backingScaleFactor ?? 2
            let path = summary.flatMap { s in s.thumbRev > 0 ? model.handle?.thumbPath(assetId: s.id, rev: s.thumbRev) : nil }
            item.tile.configure(summary, path: path, scale: scale, moment: summary.flatMap { source?.moment(for: $0.id) })
        }

        private func pageLoaded(_ range: Range<Int>) {
            guard let collection else { return }
            for indexPath in collection.indexPathsForVisibleItems() where range.contains(indexPath.item) {
                if let item = collection.item(at: indexPath) as? AssetItem { configure(item, at: indexPath.item) }
            }
        }

        // MARK: Visible range

        private func visibleRange() -> Range<Int>? {
            guard let collection else { return nil }
            let items = collection.indexPathsForVisibleItems().map(\.item)
            guard let lo = items.min(), let hi = items.max() else { return nil }
            return lo..<(hi + 1)
        }

        private func topVisibleIndex() -> Int? {
            guard let collection else { return nil }
            return collection.indexPathsForVisibleItems().map(\.item).min()
        }

        private func visibleChanged() {
            guard let range = visibleRange(), let source else { return }
            source.ensure(range)
            // What is on screen is indexed first (plan lane 1), while indexing is running.
            guard (model.progress?.mediaRemaining ?? 0) > 0 else { return }
            prioritizeTask?.cancel()
            prioritizeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, let source = self.source else { return }
                let ids = range.prefix(300).compactMap { source.id(at: $0) }
                try? await self.model.handle?.prioritize(assetIds: ids)
            }
        }

        private func refreshWindowState() {
            guard let collection else { return }
            let active = collection.window?.isKeyWindow ?? true
            for case let item as AssetItem in collection.visibleItems() {
                item.tile.windowIsActive = active
                item.tile.nameField.textColor = item.isSelected && active ? .alternateSelectedControlTextColor : .labelColor
            }
        }

        // MARK: Selection

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

        func selectionChanged() {
            guard !applyingSelection, let collection, let source else { return }
            let paths = collection.selectionIndexPaths
            var ids = Set<Int64>()
            ids.reserveCapacity(paths.count)
            for p in paths { if let id = source.id(at: p.item) { ids.insert(id) } }
            if ids != model.selectedIDs { model.selectedIDs = ids }
        }

        private func applySelectionFromModel() {
            guard let collection, let source else { return }
            let wanted = model.selectedIDs
            let current = collection.selectionIndexPaths
            let currentIDs = Set(current.compactMap { source.id(at: $0.item) })
            guard currentIDs != wanted else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            if wanted.isEmpty {
                collection.deselectAll(nil)
            } else if wanted.count == source.count {
                collection.selectAll(nil)
            } else if wanted.count <= 5_000 {
                let indexes = wanted.compactMap { source.results.indexOf(id: $0) }.map { IndexPath(item: Int($0), section: 0) }
                collection.selectionIndexPaths = Set(indexes)
            }
        }

        func selectAll() {
            guard let source else { return }
            model.selectedIDs = Set(source.results.allIds())
        }

        // MARK: Keys and menus

        private var selectedList: [Int64] {
            guard let source, let collection else { return [] }
            return collection.selectionIndexPaths.sorted().compactMap { source.id(at: $0.item) }
        }

        func quickLook() {
            let ids = selectedList
            guard !ids.isEmpty else { return }
            Task { await QuickLookController.shared.show(model: model, ids: ids) }
        }

        func openViewer() {
            guard let id = selectedList.first else { return }
            rememberZoomSource(for: id)
            model.openViewer(id)
        }

        /// Notes where the tile is on screen and what it shows, so the Viewer can grow out of it.
        func rememberZoomSource(for id: Int64) {
            guard let collection, let source, let window = collection.window,
                  let index = source.results.indexOf(id: id),
                  let item = collection.item(at: IndexPath(item: Int(index), section: 0)) as? AssetItem else { return }
            let tile = item.tile
            // A real thumbnail only: a placeholder symbol would zoom as a grey square.
            guard let summary = tile.summary, summary.thumbRev > 0, let image = tile.imageView.image, image.size.width > 48 else { return }
            let rect = window.convertToScreen(tile.imageView.convert(tile.imageView.bounds, to: nil))
            model.pendingZoom = ZoomSource(assetID: id, screenRect: rect, image: image, openedAt: .now)
        }

        func rate(_ stars: UInt8) {
            let ids = selectedList
            guard !ids.isEmpty else { return }
            Task { await model.setRating(stars, for: ids) }
        }

        func flag(_ flag: Flag) {
            let ids = selectedList
            guard !ids.isEmpty else { return }
            Task { await model.setFlag(flag, for: ids) }
        }

        func removeFromCollection() {
            guard case .collection(let id) = model.sidebar else { return }
            let ids = selectedList
            guard !ids.isEmpty else { return }
            Task { await model.removeFromCollection(id, ids: ids) }
        }

        func contextMenu() -> NSMenu {
            let ids = selectedList
            let summary = ids.count == 1 ? model.selectedSummaries.first : nil
            return AssetMenu.make(model: model, ids: ids, summary: summary)
        }

        // Double-click opens the Viewer.
        func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
            if let event = NSApp.currentEvent, event.type == .leftMouseDown, event.clickCount == 2, let first = indexPaths.first,
               let id = source?.id(at: first.item) {
                rememberZoomSource(for: id)
                model.openViewer(id)
            }
            return indexPaths
        }

        // MARK: Drag out (plan W1)

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            indexPaths.contains { index in source?.id(at: index.item).flatMap { source?.path(for: $0) } != nil }
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard let id = source?.id(at: indexPath.item), let url = source?.path(for: id) else { return nil }
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(String(id), forType: .assetID)
            return item
        }
    }
}
