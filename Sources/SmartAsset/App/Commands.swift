// The menu bar. Every toolbar button and shortcut has a menu item (bama mac-design).
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    let selectionCount: Int
    let onDuplicates: Bool
    let tickedCopies: Int
    let recentSearchCount: Int
    let meaningReady: Bool

    private var hasSelection: Bool { selectionCount > 0 }
    private var ids: [Int64] { Array(model.selectedIDs) }

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        InspectorCommands()

        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") { Task { await model.chooseFolders() } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("New Collection…") { model.promptNewCollection() }
                .keyboardShortcut("n")
            Divider()
            Button("Open in Viewer") { if let id = ids.first { model.openViewer(id) } }
                .disabled(selectionCount != 1)
            Button("Quick Look") { Task { await QuickLookController.shared.show(model: model, ids: ids) } }
                .disabled(!hasSelection)
            Button("Show in Finder") { Task { await model.showInFinder(ids) } }
                .keyboardShortcut("r")
                .disabled(!hasSelection)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button("as Grid") { model.viewMode = .grid }.keyboardShortcut("1")
            Button("as List") { model.viewMode = .list }.keyboardShortcut("2")
            Toggle("Crop Thumbnails to Squares", isOn: Binding(get: { model.cropThumbnails }, set: { model.cropThumbnails = $0 }))
            Toggle("Show File Names", isOn: Binding(get: { model.showFileNames }, set: { model.showFileNames = $0 }))
            Toggle("Show Ratings on Thumbnails", isOn: Binding(get: { model.showRatingsOnThumbnails }, set: { model.showRatingsOnThumbnails = $0 }))
            Divider()
            Button("Make Thumbnails Larger") { model.thumbSize = min(Metrics.thumbMax, model.thumbSize + 32) }
                .keyboardShortcut("+")
            Button("Make Thumbnails Smaller") { model.thumbSize = max(Metrics.thumbMin, model.thumbSize - 32) }
                .keyboardShortcut("-")
            Divider()
            Menu("Sort By") {
                ForEach(SortChoice.menu) { choice in
                    Button(choice.title) { model.sort = choice }
                }
            }
        }

        CommandMenu("Library") {
            Button("Search") { model.openSearchInCurrentPage() }
                .keyboardShortcut("f")
            Button("Search Everywhere") { model.openSearch(scope: .everywhere) }
                .keyboardShortcut("k")
            Button("More Like This") { if let id = ids.first { Task { await model.moreLikeThis(id) } } }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(selectionCount != 1 || !meaningReady)
            Button("Clear Recent Searches") { model.recentSearches.clear() }
                .disabled(recentSearchCount == 0)
            Divider()
            Button(model.isPaused ? "Resume Indexing" : "Pause Indexing") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Cancel Indexing") { Task { await model.cancelIndexing() } }
            Button("Index Unfinished Files") { Task { await model.reindexUnfinished() } }
            Divider()
            Button("Rescan All Folders") { Task { await model.rescan() } }
            Button("Show Missing Files") { model.sidebar = .missing }
            Divider()
            Button("Show All Files") { model.sidebar = .all }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("Show Duplicates") { model.sidebar = .duplicates }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Select Extra Copies in All Groups") { Task { await model.selectExtraCopiesInAllGroups() } }
                .disabled(!onDuplicates)
            Button("Move Ticked Copies to the Trash…") { Task { await model.reviewTickedCopies() } }
                .disabled(!onDuplicates || tickedCopies == 0)
            Button("Open the Trash") { model.showTrash() }
        }

        CommandMenu("Organize") {
            Menu("Rating") {
                ForEach((0...5).reversed(), id: \.self) { stars in
                    Button(stars == 0 ? "No Rating" : String(repeating: "★", count: stars)) { Task { await model.setRating(UInt8(stars), for: ids) } }
                }
                Text("In the grid, press 0–5")
            }
            .disabled(!hasSelection)
            Menu("Flag") {
                Button("Pick") { Task { await model.setFlag(.pick, for: ids) } }
                Button("Reject") { Task { await model.setFlag(.reject, for: ids) } }
                Button("Clear Flag") { Task { await model.setFlag(.none, for: ids) } }
                Text("In the grid, press P, X or U")
            }
            .disabled(!hasSelection)
            Menu("Color Label") {
                ForEach([ColorLabel.red, .orange, .yellow, .green, .blue, .purple, .gray], id: \.self) { c in
                    Button(FilterText.colorName(c)) { Task { await model.setColorLabel(c, for: ids) } }
                }
                Divider()
                Button("No Label") { Task { await model.setColorLabel(.none, for: ids) } }
            }
            .disabled(!hasSelection)
            Divider()
            Button("Add Tags…") { model.promptAddTags(to: ids) }.disabled(!hasSelection)
            Menu("Add to Collection") {
                ForEach(model.collections) { c in Button(c.name) { Task { await model.addToCollection(c.id, ids: ids) } } }
                if !model.collections.isEmpty { Divider() }
                Button("New Collection…") { model.promptNewCollection(adding: ids) }
            }
            .disabled(!hasSelection)
        }
    }
}
