// The list view (plan V6): sortable columns over the same paged result set as the grid.
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI

final class AssetTableView: NSTableView {
    weak var coordinator: AssetListView.Coordinator?

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
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return coordinator?.contextMenu()
    }
}

struct AssetListView: NSViewRepresentable {
    var model: AppModel
    var source: PagedSource?
    var generation: Int
    var thumbsGeneration: Int
    var sort: SortChoice

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = AssetTableView()
        table.coordinator = coordinator
        table.style = .inset
        table.rowHeight = Metrics.rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.setDraggingSourceOperationMask(DragPolicy.toOtherApps, forLocal: false)
        table.setDraggingSourceOperationMask(DragPolicy.withinApp, forLocal: true)
        table.setAccessibilityLabel("Files")
        for column in Coordinator.columns {
            let c = NSTableColumn(identifier: column.id)
            c.title = column.title
            c.width = column.width
            c.minWidth = column.minWidth
            c.resizingMask = column.id == Coordinator.nameID ? .autoresizingMask : .userResizingMask
            if let key = column.sortKey {
                c.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: column.defaultAscending)
            }
            table.addTableColumn(c)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.attach(table: table, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(source: source, generation: generation, thumbsGeneration: thumbsGeneration, sort: sort)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct Column {
            let id: NSUserInterfaceItemIdentifier
            let title: String
            let width: CGFloat
            let minWidth: CGFloat
            let sortKey: String?
            let defaultAscending: Bool
        }

        static let nameID = NSUserInterfaceItemIdentifier("name")
        static let columns: [Column] = [
            Column(id: nameID, title: "Name", width: 208, minWidth: 140, sortKey: "name", defaultAscending: true),
            Column(id: .init("kind"), title: "Kind", width: 56, minWidth: 48, sortKey: "kind", defaultAscending: true),
            Column(id: .init("date"), title: "Date", width: 96, minWidth: 80, sortKey: "dateCaptured", defaultAscending: false),
            Column(id: .init("duration"), title: "Duration", width: 64, minWidth: 52, sortKey: "duration", defaultAscending: false),
            Column(id: .init("dimensions"), title: "Dimensions", width: 92, minWidth: 76, sortKey: nil, defaultAscending: true),
            Column(id: .init("size"), title: "Size", width: 68, minWidth: 52, sortKey: "size", defaultAscending: false),
            Column(id: .init("rating"), title: "Rating", width: 64, minWidth: 52, sortKey: "rating", defaultAscending: false),
        ]
        private static let sortKeys: [String: SortKey] = [
            "name": .name, "kind": .kind, "dateCaptured": .dateCaptured, "duration": .duration, "size": .size, "rating": .rating,
        ]
        private static let dateFormat: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f
        }()

        let model: AppModel
        private var source: PagedSource?
        private weak var table: AssetTableView?
        private weak var scroll: NSScrollView?
        private var generation = -1
        private var thumbsGeneration = -1
        private var applyingSelection = false
        private var applyingSort = false
        private let observers = ObserverBag()

        init(model: AppModel) { self.model = model }

        func attach(table: AssetTableView, scroll: NSScrollView) {
            self.table = table
            self.scroll = scroll
            observers.add(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibleChanged() }
            })
        }

        func update(source newSource: PagedSource?, generation newGeneration: Int, thumbsGeneration newThumbs: Int, sort: SortChoice) {
            guard let table else { return }
            applyingSort = true
            if let column = Self.columns.first(where: { c in c.sortKey.flatMap { Self.sortKeys[$0] } == sort.key }), sort.key != .manual {
                table.sortDescriptors = [NSSortDescriptor(key: column.sortKey, ascending: !sort.descending)]
            }
            applyingSort = false
            if newGeneration != generation {
                let anchorID = visibleRows().lowerBound.flatMap { source?.id(at: $0) }
                generation = newGeneration
                source?.onLoaded = nil
                source = newSource
                source?.onLoaded = { [weak self] range in self?.pageLoaded(range) }
                table.reloadData()
                if let anchorID, let index = source?.results.indexOf(id: anchorID) { table.scrollRowToVisible(Int(index)) }
                applySelectionFromModel()
                visibleChanged()
            } else {
                applySelectionFromModel()
            }
            if newThumbs != thumbsGeneration {
                thumbsGeneration = newThumbs
                if let range = visibleRows().range { source?.refresh(range) }
            }
        }

        private func visibleRows() -> (range: Range<Int>?, lowerBound: Int?) {
            guard let table, let scroll else { return (nil, nil) }
            let rows = table.rows(in: scroll.contentView.bounds)
            guard rows.length > 0 else { return (nil, nil) }
            return (rows.location..<(rows.location + rows.length), rows.location)
        }

        private func visibleChanged() {
            if let range = visibleRows().range { source?.ensure(range) }
        }

        private func pageLoaded(_ range: Range<Int>) {
            guard let table, let visible = visibleRows().range else { return }
            let changed = IndexSet(integersIn: range.clamped(to: visible))
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { source?.count ?? 0 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            source?.ensure(row..<(row + 1))
            let summary = source?.summary(at: row)
            if tableColumn.identifier == Self.nameID { return nameCell(tableView, summary: summary) }
            let cell = textCell(tableView, id: tableColumn.identifier)
            cell.textField?.stringValue = summary.map { text(for: $0, column: tableColumn.identifier.rawValue) } ?? ""
            cell.textField?.alignment = ["size", "duration"].contains(tableColumn.identifier.rawValue) ? .right : .left
            cell.textField?.textColor = (summary?.missing ?? false) || !(summary?.volumeOnline ?? true) ? .secondaryLabelColor : .labelColor
            return cell
        }

        private func text(for s: AssetSummaryDto, column: String) -> String {
            switch column {
            case "kind": return s.kind.label
            case "date": return Self.dateFormat.string(from: Date(timeIntervalSince1970: Double(s.sortDate) / 1000))
            case "duration": return s.durationMs.map { Format.duration(milliseconds: $0) } ?? "—"
            case "dimensions": return Format.dimensions(width: s.width, height: s.height) ?? "—"
            case "size": return Format.fileSize(s.size)
            case "rating": return s.rating > 0 ? String(repeating: "★", count: Int(s.rating)) : "—"
            default: return ""
            }
        }

        private func textCell(_ tableView: NSTableView, id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return reused }
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func nameCell(_ tableView: NSTableView, summary: AssetSummaryDto?) -> NSView {
            let id = Self.nameID
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyDown
                image.wantsLayer = true
                image.layer?.cornerRadius = 3
                image.layer?.masksToBounds = true
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(image)
                cell.addSubview(field)
                cell.imageView = image
                cell.textField = field
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 40),
                    image.heightAnchor.constraint(equalToConstant: 26),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            guard let s = summary else {
                cell.textField?.stringValue = ""
                cell.imageView?.image = nil
                return cell
            }
            cell.textField?.stringValue = s.name
            cell.textField?.textColor = s.missing || !s.volumeOnline ? .secondaryLabelColor : .labelColor
            let symbol = NSImage(systemSymbolName: s.probeState == .failed ? "exclamationmark.triangle" : s.kind.symbol, accessibilityDescription: nil)
            cell.imageView?.image = symbol
            cell.imageView?.contentTintColor = .tertiaryLabelColor
            if s.thumbRev > 0, let path = model.handle?.thumbPath(assetId: s.id, rev: s.thumbRev) {
                if let cached = ThumbnailLoader.shared.cached(id: s.id, rev: s.thumbRev, bucket: 128) {
                    cell.imageView?.image = cached
                    cell.imageView?.contentTintColor = nil
                } else {
                    let (id, rev) = (s.id, s.thumbRev)
                    ThumbnailLoader.shared.load(id: id, rev: rev, path: path, bucket: 128) { [weak cell, weak self] image in
                        guard let cell, let image, let row = self?.table?.row(for: cell), row >= 0,
                              self?.source?.summary(at: row)?.id == id else { return }
                        cell.imageView?.image = image
                        cell.imageView?.contentTintColor = nil
                    }
                }
            }
            return cell
        }

        // MARK: Sorting and selection

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applyingSort, let descriptor = tableView.sortDescriptors.first, let name = descriptor.key,
                  let key = Self.sortKeys[name] else { return }
            model.sort = SortChoice(key: key, descending: !descriptor.ascending)
        }

        func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }

        func selectionChanged() {
            guard !applyingSelection, let table, let source else { return }
            var ids = Set<Int64>()
            for row in table.selectedRowIndexes { if let id = source.id(at: row) { ids.insert(id) } }
            if ids != model.selectedIDs { model.selectedIDs = ids }
        }

        private func applySelectionFromModel() {
            guard let table, let source else { return }
            let current = Set(table.selectedRowIndexes.compactMap { source.id(at: $0) })
            guard current != model.selectedIDs else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            if model.selectedIDs.isEmpty {
                table.deselectAll(nil)
            } else if model.selectedIDs.count == source.count {
                table.selectAll(nil)
            } else if model.selectedIDs.count <= 5_000 {
                let rows = model.selectedIDs.compactMap { source.results.indexOf(id: $0) }.map { Int($0) }
                table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
            }
        }

        private var selectedList: [Int64] {
            guard let table, let source else { return [] }
            return table.selectedRowIndexes.compactMap { source.id(at: $0) }
        }

        func quickLook() { let ids = selectedList; if !ids.isEmpty { Task { await QuickLookController.shared.show(model: model, ids: ids) } } }
        func openViewer() { if let id = selectedList.first { model.openViewer(id) } }
        func rate(_ stars: UInt8) { let ids = selectedList; if !ids.isEmpty { Task { await model.setRating(stars, for: ids) } } }
        func flag(_ flag: Flag) { let ids = selectedList; if !ids.isEmpty { Task { await model.setFlag(flag, for: ids) } } }

        func contextMenu() -> NSMenu {
            let ids = selectedList
            return AssetMenu.make(model: model, ids: ids, summary: ids.count == 1 ? model.selectedSummaries.first : nil)
        }

        func tableView(_ tableView: NSTableView, shouldTypeSelectFor event: NSEvent, withCurrentSearch searchString: String?) -> Bool {
            // Space and digits are shortcuts here, not type-to-select.
            guard let chars = event.characters else { return true }
            return !(chars == " " || (chars.count == 1 && "012345pxu".contains(chars)))
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let id = source?.id(at: row), let url = source?.path(for: id) else { return nil }
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(String(id), forType: .assetID)
            return item
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0, let id = source?.id(at: sender.clickedRow) else { return }
            model.openViewer(id)
        }
    }
}
