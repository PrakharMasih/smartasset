// The library window: sidebar, content, inspector (plan §12.3 flow rules).
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            ContentArea()
                .navigationTitle(title)
                .navigationSubtitle(model.statusText)
                // Pages with nothing to inspect (Search home, Duplicates) close it without forgetting the person's choice:
                // SwiftUI writes that forced "closed" back, so only a toggle on a page that can show it is recorded.
                .inspector(isPresented: Binding(get: { model.inspectorVisible && canInspect },
                                                set: { if canInspect { model.inspectorVisible = $0 } })) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
                }
        }
        .toolbar { MainToolbar() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFolders(from: providers)
            return true
        }
        .overlay { if dropTargeted { DropOverlay() } }
        .sheet(item: $model.collectionRequest) { request in
            NameSheet(title: "New Collection", prompt: "Name", confirm: "Create", initial: "") { name in
                await model.createCollection(named: name, adding: request.adding)
            }
        }
        .sheet(item: $model.tagRequest) { request in
            NameSheet(title: "Add Tags", prompt: "Tags, separated by commas", confirm: "Add", initial: "") { text in
                let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                await model.addTags(names, to: request.ids)
            }
        }
        .sheet(isPresented: $model.smartCollectionRequest) {
            NameSheet(title: "New Smart Collection", prompt: "Name", confirm: "Save", initial: "") { name in
                await model.saveSmartCollection(named: name)
            }
        }
        .sheet(item: $model.renaming) { item in
            NameSheet(title: item.title, prompt: "Name", confirm: "Rename", initial: item.currentName) { name in
                await model.rename(item, to: name)
            }
        }
        .sheet(item: $model.folderToExclude) { folder in
            ExcludeSheet(folder: folder)
        }
        .alert("Remove \(model.missingRemoval?.count ?? 0) Missing File\(model.missingRemoval?.count == 1 ? "" : "s") from SmartAsset?",
               isPresented: Binding(get: { model.missingRemoval != nil }, set: { if !$0 { model.missingRemoval = nil } }),
               presenting: model.missingRemoval) { removal in
            Button("Remove", role: .destructive) { Task { await model.removeMissing(removal) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They leave your library, with their ratings, tags and notes. Files that are still on your Mac are never removed. Your files are not touched.")
        }
        .alert("Remove “\(model.folderToRemove?.displayName ?? "")” from SmartAsset?",
               isPresented: Binding(get: { model.folderToRemove != nil }, set: { if !$0 { model.folderToRemove = nil } }),
               presenting: model.folderToRemove) { folder in
            Button("Remove", role: .destructive) { Task { await model.removeFolder(folder.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text("\(folder.assetCount.formatted()) file\(folder.assetCount == 1 ? "" : "s") will leave your library, with their ratings, tags and notes. Your files are not touched.")
        }
        .background(WindowFocusClearer())
        .task {
            model.undoManager = undoManager
            model.openViewerAction = { id in openWindow(id: "viewer", value: id) }
            model.openSettingsAction = { openSettings() }
        }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .gridArea("main", inset: 0)
    }

    private var canInspect: Bool {
        model.showsResults && !(model.folders.isEmpty && (model.stats?.total ?? 0) == 0)
    }

    private var title: String {
        switch model.sidebar {
        case .search: "Search"
        case .all: "All Files"
        case .kind(let k): k.label + "s"
        case .missing: "Missing Files"
        case .duplicates: "Duplicates"
        case .folder(let id): model.folders.first { $0.id == id }?.displayName ?? "Folder"
        case .collection(let id): model.collections.first { $0.id == id }?.name ?? "Collection"
        case .smart(let id): model.smartCollections.first { $0.id == id }?.name ?? "Smart Collection"
        case .tag(let name): "#\(name)"
        }
    }

    private func loadFolders(from providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.hasDirectoryPath else { return }
                Task { @MainActor in await model.addFolders([url]) }
            }
        }
    }
}

/// Windows open calm: no control has focus until the person clicks or tabs (bama mac-design).
private struct WindowFocusClearer: View {
    var body: some View { Color.clear.frame(width: 0, height: 0).noInitialFocus() }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 4, dash: [8, 8]))
            .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                Label("Drop folders to add them", systemImage: "folder.badge.plus")
                    .font(.title3.weight(.medium))
                    .padding(Space.lg)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(Space.sm)
            .allowsHitTesting(false)
    }
}

// MARK: - Content

struct ContentArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                ProgressView("Opening your library…").controlSize(.regular)
            case .failed(let message):
                ContentUnavailableView {
                    Label("SmartAsset Can’t Open the Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Quit") { NSApp.terminate(nil) }
                }
            case .ready:
                if showsWelcome {
                    WelcomeView()
                } else {
                    browser
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let banner = model.banner { BannerView(banner: banner) }
                if case .missing = model.sidebar, model.resultCount > 0 { MissingBar() }
                if model.showsKindScope, !showsWelcome { KindScopeBar() }
                if model.showsFilterBar { FilterBar() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { if model.phase == .ready && !showsWelcome { StatusBar() } }
    }

    private var showsWelcome: Bool {
        model.folders.isEmpty && (model.stats?.total ?? 0) == 0
    }

    @ViewBuilder private var browser: some View {
        switch model.sidebar {
        case .duplicates: DuplicatesView()
        case .search: SearchPage()
        default: FilesView()
        }
    }
}

/// The grid or the list of the current results. Every page that shows files uses it, the Search page included.
struct FilesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.viewMode {
            case .grid:
                AssetGridView(model: model, source: model.source, generation: model.resultsGeneration,
                              thumbSize: model.thumbSize, thumbsGeneration: model.thumbsGeneration, showNames: model.showFileNames, crop: model.cropThumbnails)
            case .list:
                AssetListView(model: model, source: model.source, generation: model.resultsGeneration,
                              thumbsGeneration: model.thumbsGeneration, sort: model.sort)
            }
            if model.resultCount == 0 && !model.isSearching && model.source != nil { EmptyResults() }
        }
        // Pictures sit on a deeper backdrop than the window so they stand out. The list is text, so it keeps the window's.
        .background(model.viewMode == .grid ? Surface.content : Color.clear)
    }
}

private struct EmptyResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.sidebar == .search, let like = model.searchLike {
            if model.likeWaiting {
                ContentUnavailableView {
                    Label("Not Looked At Yet", systemImage: "hourglass")
                } description: {
                    Text("SmartAsset hasn’t finished looking at “\(like.name)”. Try again in a moment.")
                } actions: {
                    Button("Search Again") { model.requery() }
                }
            } else {
                ContentUnavailableView {
                    Label("Nothing Else Looks Like This", systemImage: "sparkle.magnifyingglass")
                } description: {
                    Text(model.searchScope == .everywhere ? "No other file in your library has been looked at yet, or a filter leaves none."
                                                          : "Nothing in \(model.searchScopeName) looks like it. Try searching everywhere.")
                } actions: {
                    if model.searchScope != .everywhere { Button("Search Everywhere") { model.searchScope = .everywhere } }
                    if !model.filters.isEmpty { Button("Clear Filters") { model.filters = Filters.none } }
                }
            }
        } else if model.sidebar == .search {
            let words = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            ContentUnavailableView {
                Label("No Files Match “\(words)”", systemImage: "magnifyingglass")
            } description: {
                Text(model.searchScope == .everywhere ? "Try fewer or different words, or remove a filter."
                                                      : "Nothing in \(model.searchScopeName) matches. Try searching everywhere.")
            } actions: {
                if model.searchScope != .everywhere { Button("Search Everywhere") { model.searchScope = .everywhere } }
                if !model.filters.isEmpty { Button("Clear Filters") { model.filters = Filters.none } }
            }
        } else if model.hasActiveSearchOrFilter {
            ContentUnavailableView {
                Label("No Files Match", systemImage: "magnifyingglass")
            } description: {
                Text("Try different words, or remove a filter.")
            } actions: {
                Button("Clear Filters") { model.clearFilters() }
            }
        } else if case .folder(let id) = model.sidebar, let folder = model.folders.first(where: { $0.id == id }) {
            folderEmpty(folder)
        } else if case .missing = model.sidebar {
            ContentUnavailableView("Nothing Is Missing", systemImage: "checkmark.circle",
                                   description: Text("Every file is where SmartAsset saw it."))
        } else if case .collection = model.sidebar {
            ContentUnavailableView("Empty Collection", systemImage: "rectangle.stack",
                                   description: Text("Drag files here, or choose Add to Collection from a file’s menu."))
        } else if (model.progress?.scanning ?? false) {
            ProgressView("Looking for files…")
        } else {
            ContentUnavailableView("No Files", systemImage: "photo.on.rectangle.angled",
                                   description: Text("Nothing in this part of your library yet."))
        }
    }

    @ViewBuilder private func folderEmpty(_ folder: FolderDto) -> some View {
        if !folder.volumeOnline {
            ContentUnavailableView("Drive Not Connected", systemImage: "externaldrive.badge.xmark",
                                   description: Text("Plug in “\(folder.volumeName)” to see this folder’s files."))
        } else if folder.scanState == .error {
            ContentUnavailableView("SmartAsset Can’t Read This Folder", systemImage: "exclamationmark.triangle",
                                   description: Text(folder.lastError ?? "Allow access in System Settings ▸ Privacy & Security, or remove the folder and add it again."))
        } else if !folder.enabled {
            ContentUnavailableView {
                Label("Folder Is Turned Off", systemImage: "pause.circle")
            } actions: {
                Button("Turn On") { Task { await model.setFolderEnabled(folder.id, true) } }
            }
        } else if folder.scanState == .scanning || folder.scanState == .pending {
            ProgressView("Looking for files…")
        } else {
            ContentUnavailableView("No Photos, Videos or Audio", systemImage: "folder",
                                   description: Text("SmartAsset found no supported files in this folder."))
        }
    }
}

// MARK: - Banner, filter bar, status bar

struct BannerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let banner: Banner

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: banner.style == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.style == .warning ? Color.yellow : Color.secondary)
            Text(banner.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            if let title = banner.actionTitle {
                Button(title) { perform() }.controlSize(.small)
            }
            Button { model.dismissBanner() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss this message")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private func perform() {
        switch banner.action {
        case .undoTrash: Task { await model.undoLastTrash() }
        case .showMissing: model.sidebar = .missing
        case .openFoldersSettings: model.settingsTab = .folders; openSettings()
        case .openModelsSettings: model.settingsTab = .models; openSettings()
        case nil: break
        }
        model.dismissBanner()
    }
}

/// The repair actions for the Missing page (plan H2).
struct MissingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The sentence wraps on its own line above the buttons: a long sentence beside buttons in one row would make the
        // content column demand more width than the window has, and the other panes would collapse.
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                Text("These files are no longer where SmartAsset saw them. If you moved them, show SmartAsset where. If they are gone, remove them from the library.")
                    .font(.callout)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Space.sm) {
                Button("Find in Folder…") { Task { await model.locateMissingFiles() } }
                    .help("Choose the folder the files moved to; SmartAsset recognises them by their content")
                Button("Remove from Library…") { model.promptRemoveMissing(ids: model.selectedIDs.isEmpty ? nil : Array(model.selectedIDs)) }
                    .help(model.selectedIDs.isEmpty ? "Remove every missing file from the library" : "Remove the selected files from the library")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.sm) {
            if !model.searchText.isEmpty, model.sidebar != .search {
                chip(title: "“\(model.searchText)”") { model.searchText = "" }
            }
            // The kind is shown by the scope bar above, not twice.
            ForEach(FilterText.chips(for: model.filters).filter { !$0.id.hasPrefix("kind:") }, id: \.id) { chip in
                self.chip(title: chip.title) { model.removeFilter(chip.id) }
            }
            Spacer()
            Button("Save as Smart Collection…") { model.smartCollectionRequest = true }
                .controlSize(.small)
                .help("Keep this search as a collection that updates itself")
            Button("Clear") { model.clearFilters() }
                .controlSize(.small)
                .help("Remove all filters and the search")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xs + 2)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chip(title: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: Space.xs) {
            Text(title).font(.callout)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this filter")
                .accessibilityLabel("Remove \(title)")
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 4)
        .background(Palette.accent.opacity(0.14), in: Capsule())
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            if let p = model.progress, p.scanning || p.mediaRemaining > 0 || p.dedupeRemaining > 0 || p.embedRemaining > 0 || p.hold != nil {
                if p.mediaTotal > 0, p.mediaRemaining > 0 {
                    ProgressView(value: Double(p.mediaDone + p.mediaFailed), total: Double(max(1, p.mediaTotal)))
                        .frame(width: 120)
                        .accessibilityLabel("Indexing progress")
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(message(p)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                    .controlSize(.small)
                    .help(model.isPaused ? "Continue indexing (⌥⌘P)" : "Stop indexing until you resume (⌥⌘P)")
                Menu {
                    Button("Cancel Indexing") { Task { await model.cancelIndexing() } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More indexing actions")
            } else if (model.stats?.total ?? 0) > 0 {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("Everything is indexed").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.showsResults, model.viewMode == .grid {
                @Bindable var model = model
                HStack(spacing: Space.xs) {
                    Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $model.thumbSize, in: Metrics.thumbMin...Metrics.thumbMax)
                        .frame(width: 96)
                        .controlSize(.small)
                        .accessibilityLabel("Thumbnail size")
                    Image(systemName: "photo").font(.body).foregroundStyle(.secondary)
                }
                .help("Make thumbnails smaller or larger (⌘− / ⌘+)")
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xs + 2)
        .frame(minHeight: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func message(_ p: ProgressDto) -> String {
        if let hold = p.hold {
            let why: String
            switch hold {
            case .user: why = "Indexing paused"
            case .battery: why = "Indexing paused while on battery"
            case .thermal: why = "Indexing paused while your Mac cools down"
            case .memory: why = "Indexing paused: your Mac is low on memory"
            }
            let left = p.mediaRemaining > 0 ? p.mediaRemaining : (p.dedupeRemaining > 0 ? p.dedupeRemaining : p.embedRemaining)
            return left > 0 ? "\(why) · \(left.formatted()) left" : why
        }
        if p.scanning && p.mediaRemaining == 0 { return "Finding files… \(p.filesDiscovered.formatted()) found" }
        if p.mediaRemaining == 0, p.dedupeRemaining == 0 { return "Preparing search by meaning · \(p.embedRemaining.formatted()) left" }
        if p.mediaRemaining == 0 { return "Comparing files for duplicates · \(p.dedupeRemaining.formatted()) left" }
        var text = "Indexing \((p.mediaDone + p.mediaFailed).formatted()) of \(p.mediaTotal.formatted())"
        if let eta = p.etaSeconds { text += " · about \(Self.eta(eta))" }
        return text
    }

    static func eta(_ seconds: UInt64) -> String {
        switch seconds {
        case ..<45: return "a minute"
        case ..<5400: return "\(max(1, Int((Double(seconds) / 60).rounded()))) min"
        default: return String(format: "%.1f h", Double(seconds) / 3600)
        }
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            @Bindable var model = model
            if model.showsResults {
                Picker("View", selection: $model.viewMode) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                    Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
                .help("Switch between grid (⌘1) and list (⌘2)")

                SortMenu()
                FilterMenu()
            }
            // On the Search page the field is the search; every other page of files has this way in.
            if model.sidebar != .search, model.sidebar != .duplicates {
                Button { model.openSearchInCurrentPage() } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help(model.searchHelp)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if model.showsResults {
                Button {
                    model.inspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide details of the selection (⌥⌘I)")
            }
        }
    }
}

struct SortMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if model.sidebar == .search {
                ForEach([SortChoice.bestMatch] + SortChoice.menu) { choice in
                    Toggle(choice.title, isOn: Binding(get: { model.searchSort == choice }, set: { if $0 { model.searchSort = choice } }))
                }
            } else {
                ForEach(SortChoice.menu) { choice in
                    Toggle(choice.title, isOn: Binding(get: { model.sort == choice }, set: { if $0 { model.sort = choice } }))
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Choose the order of files")
    }
}

struct FilterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Menu("Kind") {
                kindToggle(.image, "Images"); kindToggle(.video, "Videos"); kindToggle(.audio, "Audio")
            }
            Menu("Shape") {
                orientation(.horizontal); orientation(.vertical); orientation(.square)
            }
            Menu("Resolution") {
                ForEach([ResolutionClass.hd720, .fhd1080, .qhd1440, .uhd4k, .uhd8k], id: \.self) { r in
                    Toggle(FilterText.resolution(r), isOn: Binding(get: { model.filters.minResolution == r }, set: { model.filters.minResolution = $0 ? r : nil }))
                }
            }
            Menu("Duration") {
                durationItem("Under 30 seconds", min: nil, max: 30_000)
                durationItem("30 seconds to 2 minutes", min: 30_000, max: 120_000)
                durationItem("Over 2 minutes", min: 120_000, max: nil)
            }
            Menu("Date") {
                dateItem("Today", days: 1); dateItem("Past 7 Days", days: 7); dateItem("Past 30 Days", days: 30); dateItem("Past Year", days: 365)
            }
            Menu("Rating") {
                ForEach(1...5, id: \.self) { stars in
                    Toggle(String(repeating: "★", count: stars) + (stars < 5 ? " & up" : ""),
                           isOn: Binding(get: { model.filters.minRating == UInt8(stars) }, set: { model.filters.minRating = $0 ? UInt8(stars) : nil }))
                }
                Toggle("Unrated", isOn: Binding(get: { model.filters.unratedOnly }, set: { model.filters.unratedOnly = $0 }))
            }
            Menu("Flag") {
                Toggle("Picks", isOn: Binding(get: { model.filters.flag == .pick }, set: { model.filters.flag = $0 ? .pick : nil }))
                Toggle("Rejects", isOn: Binding(get: { model.filters.flag == .reject }, set: { model.filters.flag = $0 ? .reject : nil }))
            }
            Menu("Color Label") {
                ForEach([ColorLabel.red, .orange, .yellow, .green, .blue, .purple, .gray], id: \.self) { c in
                    Toggle(FilterText.colorName(c), isOn: Binding(get: { model.filters.colorLabels.contains(c) }, set: { model.filters.colorLabels = $0 ? [c] : [] }))
                }
            }
            Divider()
            Button("Clear Filters") { model.filters = Filters.none }
                .disabled(model.filters.isEmpty)
        } label: {
            Label("Filter", systemImage: model.filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Show only some files")
    }

    private func kindToggle(_ kind: MediaKind, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { model.filters.kinds == [kind] }, set: { model.filters.kinds = $0 ? [kind] : [] }))
    }

    private func orientation(_ o: Orientation) -> some View {
        Toggle(FilterText.orientation(o), isOn: Binding(get: { model.filters.orientations == [o] }, set: { model.filters.orientations = $0 ? [o] : [] }))
    }

    private func durationItem(_ title: String, min: Int64?, max: Int64?) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.filters.minDurationMs == min && model.filters.maxDurationMs == max && (min != nil || max != nil) },
            set: { on in model.filters.minDurationMs = on ? min : nil; model.filters.maxDurationMs = on ? max : nil }))
    }

    private func dateItem(_ title: String, days: Int) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.filters.date.map { $0.to == nil && $0.from != nil && abs(($0.from ?? 0) - Self.start(daysAgo: days)) < 90_000_000 } ?? false },
            set: { on in model.filters.date = on ? DateRange(from: Self.start(daysAgo: days), to: nil) : nil }))
    }

    private static func start(daysAgo days: Int) -> Int64 {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -(days - 1), to: day) ?? day
        return Int64(from.timeIntervalSince1970 * 1000)
    }
}

// MARK: - Sheets

struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let prompt: String
    let confirm: String
    let initial: String
    let submit: (String) async -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(title).font(.headline)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.xl)
        .onAppear { text = initial; focused = true }
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        dismiss()
        Task { await submit(value) }
    }
}

struct ExcludeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: FolderDto
    @State private var excludes: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Exclude Subfolders in “\(folder.displayName)”").font(.headline)
            Text("SmartAsset skips these folders. Files already indexed in them leave your library; your files are not touched.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if excludes.isEmpty {
                Text("No subfolders are excluded.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List {
                    ForEach(excludes, id: \.self) { path in
                        HStack {
                            Label(path, systemImage: "folder")
                            Spacer()
                            Button { excludes.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Stop excluding this folder")
                                .accessibilityLabel("Stop excluding \(path)")
                        }
                    }
                }
                .frame(height: min(220, CGFloat(excludes.count) * 28 + 12))
            }
            HStack {
                Button("Add Subfolder…") { add() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    let list = excludes
                    dismiss()
                    Task { await model.setExcludes(folder.id, list) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 420)
        .onAppear { excludes = folder.excludes }
    }

    private func add() {
        guard let root = folder.path else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.prompt = "Exclude"
        panel.message = "Choose subfolders of “\(folder.displayName)” to skip."
        guard panel.runModal() == .OK else { return }
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let rel = String(path.dropFirst(base.count + 1))
            if !excludes.contains(rel) { excludes.append(rel) }
        }
    }
}

// MARK: - Kind scope

/// All · Images · Videos · Audio over every page of files (and over Search results). It sets the same kind filter as the
/// Filter menu, so the two always agree. Counts are shown on All Files, where they are known.
struct KindScopeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Picker("Kind", selection: Binding<MediaKind?>(
                get: { model.filters.kinds.count == 1 ? model.filters.kinds.first : nil },
                set: { model.filters.kinds = $0.map { [$0] } ?? [] })) {
                Text("All").tag(MediaKind?.none)
                Text(title("Images", model.stats?.images)).tag(MediaKind?.some(.image))
                Text(title("Videos", model.stats?.videos)).tag(MediaKind?.some(.video))
                Text(title("Audio", model.stats?.audio)).tag(MediaKind?.some(.audio))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show only images, videos or audio")
            .accessibilityLabel("Kind")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xs + 2)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func title(_ name: String, _ count: Int64?) -> String {
        guard model.sidebar == .all, model.filters.isEmpty, let count else { return name }
        return "\(name) \(count.formatted())"
    }
}
