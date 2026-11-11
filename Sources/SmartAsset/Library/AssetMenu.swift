// The context menu for files, shared by the grid and the list (every action also lives in the menu bar).
import AppKit
import CoreBridge
import SmartAssetKit

nonisolated final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    nonisolated init(_ title: String, symbol: String? = nil, key: String = "", enabled: Bool = true, state: NSControl.StateValue = .off, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        isEnabled = enabled
        self.state = state
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    nonisolated required init(coder: NSCoder) { fatalError("not used") }

    @MainActor @objc private func run() { handler() }
}

@MainActor
enum AssetMenu {
    static func make(model: AppModel, ids: [Int64], summary: AssetSummaryDto?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard !ids.isEmpty else { return menu }
        let one = ids.count == 1
        let plural = one ? "" : " (\(ids.count))"

        menu.addItem(ActionItem("Quick Look", symbol: "eye") { Task { await QuickLookController.shared.show(model: model, ids: ids) } })
        menu.addItem(ActionItem("Open in Viewer", symbol: "arrow.up.left.and.arrow.down.right", enabled: one) { model.openViewer(ids[0]) })
        menu.addItem(ActionItem("More Like This", symbol: "sparkle.magnifyingglass", enabled: one && model.semantic == .ready && summary?.kind != .audio) { Task { await model.moreLikeThis(ids[0]) } })
        menu.addItem(ActionItem("Open", symbol: "arrow.up.forward.app") { Task { await model.openWithDefaultApp(ids) } })
        menu.addItem(ActionItem("Show in Finder", symbol: "folder") { Task { await model.showInFinder(ids) } })
        menu.addItem(.separator())

        let rating = NSMenuItem(title: "Rating\(plural)", action: nil, keyEquivalent: "")
        let ratingMenu = NSMenu()
        for stars in (0...5).reversed() {
            let title = stars == 0 ? "No Rating" : String(repeating: "★", count: stars)
            ratingMenu.addItem(ActionItem(title, state: one && summary?.rating == UInt8(stars) ? .on : .off) { Task { await model.setRating(UInt8(stars), for: ids) } })
        }
        rating.submenu = ratingMenu
        menu.addItem(rating)

        let flag = NSMenuItem(title: "Flag", action: nil, keyEquivalent: "")
        let flagMenu = NSMenu()
        flagMenu.addItem(ActionItem("Pick", symbol: "flag.fill", state: one && summary?.flag == .pick ? .on : .off) { Task { await model.setFlag(.pick, for: ids) } })
        flagMenu.addItem(ActionItem("Reject", symbol: "xmark.circle", state: one && summary?.flag == .reject ? .on : .off) { Task { await model.setFlag(.reject, for: ids) } })
        flagMenu.addItem(ActionItem("Clear Flag") { Task { await model.setFlag(.none, for: ids) } })
        flag.submenu = flagMenu
        menu.addItem(flag)

        let label = NSMenuItem(title: "Color Label", action: nil, keyEquivalent: "")
        let labelMenu = NSMenu()
        for color in [ColorLabel.red, .orange, .yellow, .green, .blue, .purple, .gray, .none] {
            let item = ActionItem(color == .none ? "No Label" : FilterText.colorName(color), state: one && summary?.colorLabel == color ? .on : .off) {
                Task { await model.setColorLabel(color, for: ids) }
            }
            if let ns = LabelColors.color(color) {
                item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(paletteColors: [ns]))
            }
            labelMenu.addItem(item)
        }
        label.submenu = labelMenu
        menu.addItem(label)

        menu.addItem(.separator())
        let collection = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: "")
        collection.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)
        let collectionMenu = NSMenu()
        for c in model.collections {
            collectionMenu.addItem(ActionItem(c.name) { Task { await model.addToCollection(c.id, ids: ids) } })
        }
        if !model.collections.isEmpty { collectionMenu.addItem(.separator()) }
        collectionMenu.addItem(ActionItem("New Collection…") { model.promptNewCollection(adding: ids) })
        collection.submenu = collectionMenu
        menu.addItem(collection)
        menu.addItem(ActionItem("Add Tags…", symbol: "tag") { model.promptAddTags(to: ids) })

        if summary?.missing == true || (!one && model.selectedSummaries.contains { $0.missing }) {
            menu.addItem(.separator())
            let missingIDs = model.selectedSummaries.filter(\.missing).map(\.id)
            menu.addItem(ActionItem("Remove from Library…", symbol: "trash.slash") { model.promptRemoveMissing(ids: missingIDs.isEmpty ? ids : missingIDs) })
        }
        if case .collection(let id) = model.sidebar {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Remove from Collection", symbol: "minus.circle") { Task { await model.removeFromCollection(id, ids: ids) } })
        }
        return menu
    }
}
