// App-wide state shared by the sidebar, grid, list, inspector, menus and Viewer.
import AppKit
import CoreBridge
import Embedding
import Foundation
import Observation
import SmartAssetKit
import Workers

enum ViewMode: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
}

/// A short message under the toolbar. Information fades away by itself; warnings stay until dismissed.
struct Banner: Identifiable, Equatable {
    enum Style { case info, warning }
    let id = UUID()
    var text: String
    var style: Style = .info
    var actionTitle: String?
    var action: BannerAction?
}

enum BannerAction: Equatable {
    case undoTrash
    case showMissing
    case openFoldersSettings
    case openModelsSettings
}

@Observable
final class AppModel {
    // MARK: Boot

    enum Phase: Equatable {
        case launching
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    private(set) var engine: CoreEngine?
    var handle: EngineHandle? { engine?.handle }

    @ObservationIgnored private var worker: MediaWorker?
    @ObservationIgnored private var perceptualWorker: PerceptualWorker?
    @ObservationIgnored var embeddingWorker: EmbeddingWorker?
    @ObservationIgnored private var textWorker: TextWorker?
    @ObservationIgnored var embeddingModel: (any EmbeddingModel)?
    /// Downloading the search model (H5): only when the person chooses it in Settings ▸ Models.
    let modelDownload = ModelDownload(model: PinnedModels.embeddingGemma2)
    /// A start time asked for by the Moments row, used once by the Viewer for that file.
    @ObservationIgnored var viewerStart: (id: Int64, seconds: Double)?
    /// The search model loading in the background; quitting waits for it (it runs on the GPU).
    @ObservationIgnored var semanticLoad: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored let folderAccess = FolderAccess()
    @ObservationIgnored private let volumeMonitor = VolumeMonitor()
    @ObservationIgnored var undoManager: UndoManager?

    // MARK: Library data

    private(set) var folders: [FolderDto] = []
    private(set) var collections: [CollectionDto] = []
    private(set) var smartCollections: [SmartCollectionDto] = []
    private(set) var tags: [TagDto] = []
    private(set) var stats: LibraryStatsDto?
    private(set) var progress: ProgressDto?
    /// Search by meaning (Phase 4): whether the model is loading, ready, or not available.
    var semantic: SemanticState = .loading {
        didSet { MenuState.shared.update(meaningReady: semantic == .ready) }
    }
    var banner: Banner?
    var notices: [NoticeDto] = []

    // MARK: Duplicates (plan A1–A3)

    /// The groups the Duplicates page shows; nil until the first answer.
    var duplicates: DuplicatesDto?
    var duplicatesLoading = false
    var duplicateTab: DuplicateTab = .exact
    /// Copies ticked for the Trash, per group. Nothing is ticked until the person ticks it.
    var dupTicks: [String: Set<Int64>] = [:] {
        didSet { MenuState.shared.update(ticked: dupTicks.values.reduce(0) { $0 + $1.count }) }
    }
    /// The review sheet, while one is open.
    var cleanupReview: CleanupReview?
    /// What the last cleanup moved, so Undo can put it back.
    var lastTrash: TrashRecord?
    @ObservationIgnored var duplicatesTask: Task<Void, Never>?

    // MARK: What is shown

    /// The app opens on Search (plan S13): finding is the first thing people do.
    var sidebar: SidebarItem = .search {
        didSet {
            guard sidebar != oldValue else { return }
            // Words belong to the Search page. Leaving it, or arriving on it from a library page, starts without them,
            // so a library page is never filtered by words nobody can see.
            if (oldValue == .search) != (sidebar == .search), !searchText.isEmpty, !keepSearchTextOnce { searchText = "" }
            keepSearchTextOnce = false
            // "More Like This" belongs to the Search page too.
            if oldValue == .search, sidebar != .search { searchLike = nil }
            if ProcessInfo.processInfo.environment["APP_TRACE_SIDEBAR"] == "1" {
                print("SIDEBAR \(oldValue) -> \(sidebar)\n" + Thread.callStackSymbols.prefix(10).joined(separator: "\n"))
            }
            MenuState.shared.update(onDuplicates: sidebar == .duplicates)
            if sidebar == .duplicates { refreshDuplicates() }
            // A collection shows its hand-made order; every other page uses the chosen sort.
            if case .collection = sidebar { sort = SortChoice(key: .manual, descending: false) }
            else if oldValue.isCollection { sort = lastSort }
            selectedIDs = []
            requery()
        }
    }

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            // Searching means looking at files: leave the Duplicates page for the library.
            if sidebar == .duplicates, !searchText.isEmpty { sidebar = .all }
            // Typing words replaces More Like This.
            if !searchText.isEmpty, searchLike != nil { searchLike = nil }
            // Results appear as you type; wait a beat so every keystroke does not run a search.
            requery(after: .milliseconds(150))
        }
    }

    /// Where the Search page looks (the "in …" chip). Only the Search page uses it.
    var searchScope: SearchScope = .everywhere {
        didSet { if searchScope != oldValue, sidebar == .search { requery() } }
    }
    /// More Like This (S7): the file whose look the Search page is searching for. While set, the page lists the files
    /// closest to it instead of matching words. Typing words, Escape, or leaving the page ends it.
    struct LikeTarget: Equatable { let id: Int64; let name: String }
    var searchLike: LikeTarget? {
        didSet { if searchLike != oldValue, sidebar == .search { requery() } }
    }
    /// True when the file being searched for has no description yet (SmartAsset has not finished looking at it).
    private(set) var likeWaiting = false

    /// The Search page's order. It starts at best match; the other pages keep `sort`.
    var searchSort: SortChoice = .bestMatch {
        didSet { if searchSort != oldValue, sidebar == .search { requery() } }
    }
    /// Searches worth coming back to, on this Mac only (never in the library file, never sent anywhere).
    var recentSearches = RecentSearches() {
        didSet {
            MenuState.shared.update(recent: recentSearches.items.count)
            if !isSnapshotRun { UserDefaults.standard.set(recentSearches.items, forKey: "search.recent") }
        }
    }
    /// Bumps to ask the Search page to put the cursor in its field (⌘F, ⌘K, the magnifier button).
    var searchFocusRequest = 0
    @ObservationIgnored var keepSearchTextOnce = false

    var filters = Filters.none {
        didSet { if filters != oldValue { requery() } }
    }

    var sort: SortChoice = .newest {
        didSet {
            guard sort != oldValue else { return }
            if sort.key != .manual { lastSort = sort }
            requery()
        }
    }
    @ObservationIgnored private var lastSort: SortChoice = .newest

    var viewMode: ViewMode = .grid {
        didSet { if !isSnapshotRun { UserDefaults.standard.set(viewMode.rawValue, forKey: "view.mode") } }
    }

    var thumbSize: Double = Metrics.thumbDefault {
        didSet {
            thumbSize = min(Metrics.thumbMax, max(Metrics.thumbMin, thumbSize))
            if !isSnapshotRun { UserDefaults.standard.set(thumbSize, forKey: "view.thumbSize") }
        }
    }

    var inspectorVisible = true

    /// View ▸ Crop Thumbnails to Squares. On, pictures fill square tiles (the gallery look); off, each picture is shown whole.
    var cropThumbnails = true {
        didSet { if !isSnapshotRun { UserDefaults.standard.set(cropThumbnails, forKey: "view.cropThumbs") } }
    }

    /// View ▸ Show File Names. Off, tiles are pictures only (the tooltip and the Inspector have the name).
    var showFileNames = false {
        didSet { if !isSnapshotRun { UserDefaults.standard.set(showFileNames, forKey: "view.showNames") } }
    }

    /// View ▸ Show Ratings on Thumbnails. Off, a rating shows while the pointer is over a tile or the tile is selected.
    var showRatingsOnThumbnails = false {
        didSet {
            TileOverlayView.alwaysShowsRating = showRatingsOnThumbnails
            if !isSnapshotRun { UserDefaults.standard.set(showRatingsOnThumbnails, forKey: "view.showRatings") }
            thumbsGeneration += 1
        }
    }
    var settingsTab: SettingsTab = .general

    private(set) var results: ResultSet?
    /// The window onto `results` that the grid and list read from.
    private(set) var source: PagedSource?
    private(set) var resultCount = 0
    /// Bumps whenever `results` is replaced, so the grid knows to reload.
    private(set) var resultsGeneration = 0
    /// Bumps when thumbnails changed, so visible tiles refresh.
    private(set) var thumbsGeneration = 0
    private(set) var isSearching = false

    var selectedIDs: Set<Int64> = [] {
        didSet {
            guard selectedIDs != oldValue else { return }
            MenuState.shared.update(count: selectedIDs.count)
            refreshSelection()
        }
    }
    private(set) var selectedSummaries: [AssetSummaryDto] = []
    private(set) var selectedDetail: AssetDetailDto?
    private(set) var selectedCollectionIDs: Set<Int64> = []

    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var queryToken = 0
    @ObservationIgnored private var lastRequery = ContinuousClock.now
    @ObservationIgnored private var selectionToken = 0
    @ObservationIgnored let isSnapshotRun = ProcessInfo.processInfo.environment["APP_SNAPSHOT"] != nil

    init() {
        let defaults = UserDefaults.standard
        if !isSnapshotRun {
            if let raw = defaults.string(forKey: "view.mode"), let mode = ViewMode(rawValue: raw) { viewMode = mode }
            let size = defaults.double(forKey: "view.thumbSize")
            if size > 0 { thumbSize = min(Metrics.thumbMax, max(Metrics.thumbMin, size)) }
            recentSearches = RecentSearches(defaults.stringArray(forKey: "search.recent") ?? [])
            showRatingsOnThumbnails = defaults.bool(forKey: "view.showRatings")
            showFileNames = defaults.bool(forKey: "view.showNames")
            if defaults.object(forKey: "view.cropThumbs") != nil { cropThumbnails = defaults.bool(forKey: "view.cropThumbs") }
        }
    }

    // MARK: Launch

    /// Where the library lives. `APP_DATA` points tests and snapshots somewhere else.
    static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["APP_DATA"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appending(path: "SmartAsset", directoryHint: .isDirectory)
    }

    func launch() async {
        guard phase == .launching else { return }
        do {
            let engine = try await CoreBridge.open(dataDirectory: Self.dataDirectory)
            self.engine = engine
            let info = engine.handle.openInfo()
            if let problem = info.databaseProblem {
                banner = Banner(text: "The library database reported a problem after the last quit: \(problem)", style: .warning)
            }
            listenForEvents(engine)
            // Browsing works before any background work starts: show the library at once.
            await refreshSidebarData()
            requery()
            phase = .ready

            // Then: drives, folder access, and the background work.
            let mounted = Volumes.mounted()
            try await engine.handle.syncVolumes(mounted: mounted)
            await reopenFolderAccess()
            volumeMonitor.start(mounted: { [weak self] volume in self?.driveConnected(volume) },
                                unmounted: { [weak self] path in self?.driveRemoved(mountPath: path) })
            try await engine.handle.start()
            let worker = MediaWorker(engine: engine.handle, events: engine.events)
            worker.start()
            self.worker = worker
            let perceptual = PerceptualWorker(engine: engine.handle, events: engine.events)
            perceptual.start()
            self.perceptualWorker = perceptual
            // Text in pictures (S4): Vision is part of macOS, so reading starts with the other workers.
            // `APP_TEXT=0` leaves it off (benchmarks, and finding out which background work a problem comes from).
            if ProcessInfo.processInfo.environment["APP_TEXT"] != "0" {
                engine.handle.setTextReader(reader: TextProcessor.reader)
                let text = TextWorker(engine: engine.handle, events: engine.events)
                text.start()
                self.textWorker = text
            }
            modelDownload.onInstalled = { [weak self] in self?.startSemanticSearch(engine) }
            modelDownload.onRemoved = { [weak self] in await self?.stopSemanticSearch() }
            startSemanticSearch(engine)
            engine.handle.setConditions(conditions: PowerMonitor.shared.conditions)
            PowerMonitor.shared.onChange = { [weak self] conditions in self?.handle?.setConditions(conditions: conditions) }
            PowerMonitor.shared.start()
        } catch let error as BridgeError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    private(set) var isShutDown = false

    /// Stops the engine and marks the session as cleanly finished. Safe to call more than once.
    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        PowerMonitor.shared.stop()
        volumeMonitor.stop()
        duplicatesTask?.cancel()
        await worker?.stop()
        await perceptualWorker?.stop()
        await embeddingWorker?.stop()
        await textWorker?.stop()
        // The model last: a loading model or a question being embedded must finish before the process may exit.
        await semanticLoad?.value
        await embeddingModel?.close()
        try? await handle?.shutdown()
        folderAccess.stopAll()
        engine?.events.finish()
    }

    // MARK: Events

    private func listenForEvents(_ engine: CoreEngine) {
        let stream = engine.events.stream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .libraryChanged(let structural):
            // Files added, moved or removed update quickly. Detail changes during indexing wait a little, because
            // each one would reshuffle a big grid.
            let busy = (progress?.mediaRemaining ?? 0) > 0
            requery(after: structural ? .milliseconds(200) : (busy ? .milliseconds(1500) : .milliseconds(250)))
            Task { await refreshStats() }
        case .thumbnailsReady:
            thumbsGeneration += 1
        case .foldersChanged:
            Task { await refreshSidebarData() }
        case .duplicatesChanged:
            // Only the open page needs fresh groups; the sidebar badge catches up when the work finishes.
            if sidebar == .duplicates { refreshDuplicates(after: .milliseconds(600)) }
        case .progress(let p):
            let wasBusy = (progress?.mediaRemaining ?? 0) > 0 || (progress?.scanning ?? false)
            let wasComparing = (progress?.dedupeRemaining ?? 0) > 0
            progress = p
            if wasBusy && p.mediaRemaining == 0 && !p.scanning {
                Task { await refreshSidebarData() }
                requery()
            }
            if wasComparing && p.dedupeRemaining == 0 { refreshDuplicates() }
        case .notice(let notice):
            show(notice)
        }
    }

    private func show(_ notice: NoticeDto) {
        switch notice {
        case .folderLooksEmpty(_, let name):
            banner = Banner(text: "Everything in “\(name)” disappeared at once, so nothing was marked missing. If its drive is connected, check access; otherwise remove the folder.",
                            style: .warning, actionTitle: "Open Folders", action: .openFoldersSettings)
        case .folderUnreadable(_, let name, _):
            // The folder may simply have been moved: bookmarks follow it (plan H2).
            Task { await refreshSidebarData(); await reopenFolderAccess() }
            banner = Banner(text: "SmartAsset can’t read “\(name)”. Allow access in System Settings ▸ Privacy & Security, or remove the folder and add it again.",
                            style: .warning, actionTitle: "Open Folders", action: .openFoldersSettings)
        case .cloudFilesSkipped(_, let name, let count):
            banner = Banner(text: "\(count) file\(count == 1 ? "" : "s") in “\(name)” \(count == 1 ? "is" : "are") only in iCloud and \(count == 1 ? "was" : "were") skipped, so nothing gets downloaded. Download them in Finder to include them.")
        case .databaseProblem(let message):
            banner = Banner(text: "The library database reported a problem: \(message)", style: .warning)
        }
    }

    func dismissBanner() { banner = nil }

    func inform(_ text: String) {
        let b = Banner(text: text)
        banner = b
        Task {
            try? await Task.sleep(for: .seconds(6))
            if banner?.id == b.id { banner = nil }
        }
    }

    // MARK: Sidebar data

    func refreshSidebarData() async {
        guard let handle else { return }
        async let f = try? handle.listFolders()
        async let c = try? handle.collections()
        async let s = try? handle.smartCollections()
        async let t = try? handle.tags()
        async let st = try? handle.stats()
        let (folders, collections, smart, tags, stats) = await (f, c, s, t, st)
        if let folders { self.folders = folders }
        if let collections { self.collections = collections }
        if let smart { self.smartCollections = smart }
        if let tags { self.tags = tags }
        if let stats { self.stats = stats }
        // A page that no longer exists falls back to All Files.
        if !sidebarExists(sidebar) { sidebar = .all }
    }

    private func refreshStats() async {
        if let stats = try? await handle?.stats() { self.stats = stats }
    }

    private func sidebarExists(_ item: SidebarItem) -> Bool {
        switch item {
        case .search, .all, .kind, .missing, .tag, .duplicates: true
        case .folder(let id): folders.contains { $0.id == id } || folders.isEmpty
        case .collection(let id): collections.contains { $0.id == id } || collections.isEmpty
        case .smart(let id): smartCollections.contains { $0.id == id } || smartCollections.isEmpty
        }
    }

    // MARK: Searching

    /// The question the grid is answering right now.
    var currentQuery: SearchQuery {
        var query = SearchQuery.everything
        var base = sidebar.baseFilters()
        switch sidebar {
        case .smart(let id):
            if let stored = smartCollections.first(where: { $0.id == id }) {
                query = stored.query
                base = stored.query.filters
            }
        case .search:
            base = searchScope.filters
        default: break
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        query.text = trimmed.isEmpty ? query.text : trimmed
        query.filters = filters.merged(over: base)
        // Smart collections keep their stored order until the person picks another.
        if case .smart(let id) = sidebar, sort == .newest, let stored = smartCollections.first(where: { $0.id == id }) {
            query.sort = stored.query.sort
        } else {
            query.sort = sort.sort
        }
        if sidebar == .search {
            // Best match needs words to rank by; without them the newest files come first.
            query.sort = query.text == nil && searchSort.key == .relevance ? SortChoice.newest.sort : searchSort.sort
        } else if query.text != nil, sort == .newest, sidebar.ranksTypedSearchByRelevance {
            // Typing a search ranks by best match unless the person chose an order.
            query.sort = Sort(key: .relevance, descending: false)
        }
        return query
    }

    var hasActiveSearchOrFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !filters.isEmpty
    }

    func requery(after delay: Duration = .zero) {
        // The Duplicates page is not a list of search results; it asks for its own groups.
        if sidebar == .duplicates { queryTask?.cancel(); return }
        queryTask?.cancel()
        queryToken += 1
        let token = queryToken
        queryTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, let handle = self.handle else { return }
            self.isSearching = true
            defer { if token == self.queryToken { self.isSearching = false } }
            do {
                let question = self.currentQuery
                var set: ResultSet
                var meaningVector: [Float] = []
                if self.sidebar == .search, let like = self.searchLike {
                    // More Like This: the file's own description is the question. Nil means it has none yet.
                    var filtersOnly = question
                    filtersOnly.text = nil
                    if let similar = try await handle.searchSimilar(assetId: like.id, query: filtersOnly) {
                        set = similar
                        self.likeWaiting = false
                    } else {
                        set = try await handle.search(query: Self.nothing)
                        self.likeWaiting = true
                    }
                } else {
                    self.likeWaiting = false
                    // Words are also given to the model, so files that match by meaning join the keyword matches.
                    let meaning = await self.meaning(of: question)
                    meaningVector = meaning
                    set = meaning.isEmpty ? try await handle.search(query: question) : try await handle.searchHybrid(query: question, vector: meaning)
                }
                // A newer question replaced this one while it ran: drop the answer.
                guard token == self.queryToken, !Task.isCancelled else { return }
                self.results = set
                // Videos found by meaning show the moment that matched on their tile (S2).
                self.source = PagedSource(results: set, handle: handle, momentsFor: meaningVector.isEmpty ? nil : (question, meaningVector))
                self.resultCount = Int(set.count())
                self.resultsGeneration += 1
                // Selected files that left the results are no longer selected.
                if !self.selectedIDs.isEmpty {
                    let still = self.selectedIDs.filter { set.indexOf(id: $0) != nil }
                    if still.count != self.selectedIDs.count { self.selectedIDs = Set(still) }
                }
            } catch {
                guard token == self.queryToken else { return }
                self.banner = Banner(text: "Search failed: \(error.userMessage)", style: .warning)
            }
        }
    }

    /// A question nothing can answer (a folder that does not exist): the empty list shown while a file waits to be described.
    private static let nothing: SearchQuery = {
        var q = SearchQuery.everything
        q.filters.folderIds = [-1]
        return q
    }()

    func clearFilters() {
        filters = Filters.none
        searchText = ""
    }

    // MARK: Selection

    private func refreshSelection() {
        selectionToken += 1
        let token = selectionToken
        let ids = Array(selectedIDs.prefix(500))
        guard let handle, !ids.isEmpty else {
            selectedSummaries = []
            selectedDetail = nil
            selectedCollectionIDs = []
            return
        }
        Task { [weak self] in
            async let summaries = try? handle.summaries(assetIds: ids)
            let single = ids.count == 1 ? ids[0] : nil
            async let detail: AssetDetailDto? = {
                guard let single else { return nil }
                return try? await handle.assetDetail(assetId: single)
            }()
            async let membership: [Int64]? = {
                guard let single else { return nil }
                return try? await handle.collectionsOf(assetId: single)
            }()
            let (s, d, m) = await (summaries, detail, membership)
            guard let self, token == self.selectionToken else { return }
            self.selectedSummaries = s ?? []
            self.selectedDetail = d
            self.selectedCollectionIDs = Set(m ?? [])
        }
    }

    // MARK: Folders

    /// Adds folders picked in the folder picker or dropped on the window. Nothing is copied.
    func addFolders(_ urls: [URL]) async {
        guard let handle else { return }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                inform("“\(url.lastPathComponent)” is a file, not a folder. Drop or choose a folder to add.")
                continue
            }
            _ = url.startAccessingSecurityScopedResource()
            guard let volume = Volumes.volume(of: url) else {
                banner = Banner(text: "SmartAsset can’t tell which drive “\(url.lastPathComponent)” is on.", style: .warning)
                continue
            }
            let bookmark = folderAccess.makeBookmark(for: url)
            do {
                let outcome = try await handle.addFolder(request: AddFolderRequestDto(path: url.path, bookmark: bookmark, volume: volume))
                switch outcome {
                case .added(let id, let absorbed):
                    folderAccess.remember(folderID: id, url: url)
                    for child in absorbed { folderAccess.forget(folderID: child) }
                    await refreshSidebarData()
                    sidebar = .folder(id)
                    showModelsHintOnce()
                    if !absorbed.isEmpty {
                        inform("“\(url.lastPathComponent)” includes \(absorbed.count) folder\(absorbed.count == 1 ? "" : "s") you added before. Their ratings and tags were kept.")
                    }
                case .alreadyAdded(let id):
                    sidebar = .folder(id)
                    inform("“\(url.lastPathComponent)” is already in your library.")
                case .insideExisting(let folderId, let name, let excluded):
                    sidebar = .folder(folderId)
                    inform(excluded
                           ? "“\(url.lastPathComponent)” is inside “\(name)”, which skips it. Turn off that exclusion in Folders."
                           : "“\(url.lastPathComponent)” is already included in “\(name)”.")
                }
            } catch {
                banner = Banner(text: "Couldn’t add “\(url.lastPathComponent)”: \(error.userMessage)", style: .warning)
            }
        }
    }

    /// First-run step after the very first folder (plan H3): the grid is already filling; point at the models, once.
    private func showModelsHintOnce() {
        let key = "onboarding.modelsHintShown"
        guard !isSnapshotRun, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        banner = Banner(text: "Your files are appearing. Next, choose which AI models to use for search by meaning and transcripts. You can do it any time.",
                        actionTitle: "Choose Models", action: .openModelsSettings)
    }

    func removeFolder(_ id: Int64) async {
        guard let handle else { return }
        do {
            try await handle.removeFolder(folderId: id)
            folderAccess.forget(folderID: id)
            await refreshSidebarData()
            if sidebar == .folder(id) { sidebar = .all }
        } catch {
            banner = Banner(text: "Couldn’t remove the folder: \(error.userMessage)", style: .warning)
        }
    }

    func setFolderEnabled(_ id: Int64, _ enabled: Bool) async {
        do { try await handle?.setFolderEnabled(folderId: id, enabled: enabled) } catch { report(error); return }
        registerUndo(enabled ? "Turn On Folder" : "Turn Off Folder") { [weak self] in await self?.setFolderEnabled(id, !enabled) }
        await refreshSidebarData()
        requery()
    }

    func setExcludes(_ id: Int64, _ paths: [String]) async {
        let before = folders.first { $0.id == id }?.excludes ?? []
        do {
            try await handle?.setExcludes(folderId: id, excludes: paths)
            // Files in a folder that is no longer excluded are found by a rescan.
            try? await handle?.rescan(folderId: id)
            await refreshSidebarData()
        } catch {
            banner = Banner(text: "Couldn’t update the excluded folders: \(error.userMessage)", style: .warning)
            return
        }
        // Excluding a folder removes its files' ratings and tags from the library, which Undo could not bring back,
        // so only a change that excludes *less* can be undone.
        if Set(paths).isStrictSubset(of: Set(before)) {
            registerUndo("Change Excluded Folders") { [weak self] in await self?.setExcludes(id, before) }
        }
    }

    func rescan(_ id: Int64? = nil) async { try? await handle?.rescan(folderId: id) }

    /// Re-opens access to every added folder with its saved bookmark, and follows folders that were moved (plan H2).
    private func reopenFolderAccess() async {
        guard let handle else { return }
        for folder in folders {
            guard let bookmark = folder.bookmark, let resolved = folderAccess.resolve(folderID: folder.id, bookmark: bookmark) else { continue }
            if let fresh = resolved.refreshedBookmark { try? await handle.updateBookmark(folderId: folder.id, bookmark: fresh) }
            // The folder was moved or renamed: macOS bookmarks follow it. Point the library at the new place.
            if let old = folder.path, old != resolved.url.path, !FileManager.default.fileExists(atPath: old),
               let volume = Volumes.volume(of: resolved.url) {
                try? await handle.relocateFolder(folderId: folder.id, newPath: resolved.url.path, bookmark: resolved.refreshedBookmark ?? bookmark, volume: volume)
                inform("“\(folder.displayName)” moved. SmartAsset followed it.")
            }
        }
        await refreshSidebarData()
    }

    private func driveConnected(_ volume: MountedVolumeDto) {
        Task {
            try? await handle?.volumeMounted(volume: volume)
            await reopenFolderAccess()
            inform("“\(volume.name)” is connected. Its files are available again.")
        }
    }

    private func driveRemoved(mountPath: String) {
        Task {
            guard let handle, let volumes = try? await handle.listVolumes(),
                  let gone = volumes.first(where: { $0.mountPath == mountPath }) else { return }
            try? await handle.volumeUnmounted(uuid: gone.uuid)
        }
    }

    // MARK: Indexing control

    var isPaused: Bool { handle?.isPaused() ?? false }

    func togglePause() {
        guard let handle else { return }
        if handle.isPaused() { handle.resumeIndexing() } else { handle.pauseIndexing() }
        // Re-read progress so the status bar changes at once.
        Task { progress = await handle.progress() }
    }

    func cancelIndexing() async {
        try? await handle?.cancelIndexing(folderId: nil)
        progress = await handle?.progress()
    }

    func reindexUnfinished() async {
        let n = (try? await handle?.reindexUnfinished()) ?? 0
        inform(n == 0 ? "Everything is already indexed." : "Indexing \(n) file\(n == 1 ? "" : "s") again.")
    }

    // MARK: Organizing (every change can be undone)

    func registerUndo(_ name: String, _ undo: @escaping @MainActor () async -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { _ in Task { @MainActor in await undo() } }
        undoManager.setActionName(name)
    }

    func setRating(_ rating: UInt8, for ids: [Int64]) async {
        guard let handle, !ids.isEmpty else { return }
        let before = (try? await handle.summaries(assetIds: ids)) ?? []
        do { try await handle.setRating(assetIds: ids, rating: rating) } catch { report(error); return }
        let groups = Dictionary(grouping: before, by: \.rating)
        registerUndo(rating == 0 ? "Clear Rating" : "Set Rating") { [weak self] in
            for (old, items) in groups { try? await self?.handle?.setRating(assetIds: items.map(\.id), rating: old) }
        }
        refreshSelection()
    }

    func setFlag(_ flag: Flag, for ids: [Int64]) async {
        guard let handle, !ids.isEmpty else { return }
        let before = (try? await handle.summaries(assetIds: ids)) ?? []
        do { try await handle.setFlag(assetIds: ids, flag: flag) } catch { report(error); return }
        let groups = Dictionary(grouping: before, by: \.flag)
        registerUndo(flag == .pick ? "Pick" : flag == .reject ? "Reject" : "Clear Flag") { [weak self] in
            for (old, items) in groups { try? await self?.handle?.setFlag(assetIds: items.map(\.id), flag: old) }
        }
        refreshSelection()
    }

    func setColorLabel(_ label: ColorLabel, for ids: [Int64]) async {
        guard let handle, !ids.isEmpty else { return }
        let before = (try? await handle.summaries(assetIds: ids)) ?? []
        do { try await handle.setColorLabel(assetIds: ids, label: label) } catch { report(error); return }
        let groups = Dictionary(grouping: before, by: \.colorLabel)
        registerUndo("Set Color Label") { [weak self] in
            for (old, items) in groups { try? await self?.handle?.setColorLabel(assetIds: items.map(\.id), label: old) }
        }
        refreshSelection()
    }

    func addTags(_ names: [String], to ids: [Int64]) async {
        guard let handle, !ids.isEmpty, !names.isEmpty else { return }
        do { try await handle.addTags(assetIds: ids, names: names) } catch { report(error); return }
        registerUndo("Add Tags") { [weak self] in try? await self?.handle?.removeTags(assetIds: ids, names: names); await self?.afterTagChange() }
        await afterTagChange()
    }

    func removeTag(_ name: String, from ids: [Int64]) async {
        guard let handle, !ids.isEmpty else { return }
        do { try await handle.removeTags(assetIds: ids, names: [name]) } catch { report(error); return }
        registerUndo("Remove Tag") { [weak self] in try? await self?.handle?.addTags(assetIds: ids, names: [name]); await self?.afterTagChange() }
        await afterTagChange()
    }

    private func afterTagChange() async {
        tags = (try? await handle?.tags()) ?? tags
        refreshSelection()
    }

    func setNotes(_ notes: String, for id: Int64) async {
        do { try await handle?.setNotes(assetId: id, notes: notes) } catch { report(error) }
    }

    func createCollection(named name: String, adding ids: [Int64] = []) async {
        guard let handle else { return }
        do {
            let id = try await handle.createCollection(name: name)
            if !ids.isEmpty { _ = try await handle.addToCollection(id: id, assetIds: ids) }
            await refreshSidebarData()
            sidebar = .collection(id)
        } catch { report(error) }
    }

    func addToCollection(_ collection: Int64, ids: [Int64]) async {
        guard let handle, !ids.isEmpty else { return }
        do {
            let added = try await handle.addToCollection(id: collection, assetIds: ids)
            let name = collections.first { $0.id == collection }?.name ?? "collection"
            inform(added == 0 ? "Already in “\(name)”." : "Added \(added) file\(added == 1 ? "" : "s") to “\(name)”.")
            registerUndo("Add to Collection") { [weak self] in
                _ = try? await self?.handle?.removeFromCollection(id: collection, assetIds: ids)
                await self?.refreshSidebarData()
                self?.requery()
            }
            await refreshSidebarData()
            refreshSelection()
        } catch { report(error) }
    }

    func removeFromCollection(_ collection: Int64, ids: [Int64]) async {
        guard let handle, !ids.isEmpty else { return }
        _ = try? await handle.removeFromCollection(id: collection, assetIds: ids)
        registerUndo("Remove from Collection") { [weak self] in
            _ = try? await self?.handle?.addToCollection(id: collection, assetIds: ids)
            await self?.refreshSidebarData()
            self?.requery()
        }
        await refreshSidebarData()
        requery()
    }

    func renameCollection(_ id: Int64, to name: String) async {
        do { try await handle?.renameCollection(id: id, name: name); await refreshSidebarData() } catch { report(error) }
    }

    func deleteCollection(_ id: Int64) async {
        try? await handle?.deleteCollection(id: id)
        await refreshSidebarData()
    }

    func saveSmartCollection(named name: String) async {
        guard let handle else { return }
        var query = currentQuery
        if case .smart = sidebar {} else { query.sort = sort.sort }
        do {
            let id = try await handle.createSmartCollection(name: name, query: query)
            await refreshSidebarData()
            sidebar = .smart(id)
            filters = Filters.none
            searchText = ""
        } catch { report(error) }
    }

    func deleteSmartCollection(_ id: Int64) async {
        try? await handle?.deleteSmartCollection(id: id)
        await refreshSidebarData()
    }

    func report(_ error: Error) {
        banner = Banner(text: error.userMessage, style: .warning)
    }

    // MARK: Sheets and windows

    /// Set by the root view, which owns `openWindow`.
    @ObservationIgnored var openViewerAction: ((Int64) -> Void)?
    /// Where the tile that is opening the Viewer sits, for the zoom into it (Viewer/ZoomTransition.swift).
    @ObservationIgnored var pendingZoom: ZoomSource?
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    var collectionRequest: CollectionRequest?
    var tagRequest: TagRequest?
    var smartCollectionRequest = false
    var folderToRemove: FolderDto?
    var folderToExclude: FolderDto?

    struct CollectionRequest: Identifiable { let id = UUID(); var adding: [Int64] }
    struct TagRequest: Identifiable { let id = UUID(); var ids: [Int64] }

    var renaming: Renaming?

    enum Renaming: Identifiable {
        case collection(Int64, String)
        case smart(Int64, String)
        case tag(String)

        var id: String {
            switch self { case .collection(let i, _): "c\(i)"; case .smart(let i, _): "s\(i)"; case .tag(let n): "t\(n)" }
        }
        var title: String {
            switch self { case .collection: "Rename Collection"; case .smart: "Rename Smart Collection"; case .tag: "Rename Tag" }
        }
        var currentName: String {
            switch self { case .collection(_, let n), .smart(_, let n), .tag(let n): n }
        }
    }

    func rename(_ item: Renaming, to name: String) async {
        do {
            switch item {
            case .collection(let id, _): try await handle?.renameCollection(id: id, name: name)
            case .smart(let id, let old):
                if let c = smartCollections.first(where: { $0.id == id }) { try await handle?.updateSmartCollection(id: id, name: name, query: c.query) }
                _ = old
            case .tag(let old): try await handle?.renameTag(from: old, to: name)
            }
            await refreshSidebarData()
            requery()
        } catch { report(error) }
    }

    /// Opens the folder picker (the only way SmartAsset gets access to a folder, plan L1b).
    func chooseFolders() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose the folders to add. SmartAsset reads them where they are and never changes your files."
        guard panel.runModal() == .OK else { return }
        await addFolders(panel.urls)
    }

    /// Removes one chip. Chip ids come from `FilterText.chips`.
    func removeFilter(_ id: String) {
        var f = filters
        switch true {
        case id.hasPrefix("kind:"): f.kinds = []
        case id.hasPrefix("orient:"): f.orientations = []
        case id == "res": f.minResolution = nil
        case id == "duration": f.minDurationMs = nil; f.maxDurationMs = nil
        case id == "date": f.date = nil
        case id == "unrated": f.unratedOnly = false
        case id == "rating": f.minRating = nil
        case id == "flag": f.flag = nil
        case id.hasPrefix("label:"): f.colorLabels = []
        case id.hasPrefix("tag:"): let name = String(id.dropFirst(4)); f.tagsAll.removeAll { $0 == name }
        default: break
        }
        filters = f
    }

    /// Opens a video in the Viewer at a chosen moment (a scene in the Inspector's Moments row).
    func openViewer(_ id: Int64, atSeconds seconds: Double) {
        viewerStart = (id, seconds)
        openViewer(id)
    }

    func openViewer(_ id: Int64) {
        // Opening a result is the surest sign a search was worth keeping.
        if sidebar == .search { commitSearch() }
        openViewerAction?(id)
    }
    func promptNewCollection(adding ids: [Int64] = []) { collectionRequest = CollectionRequest(adding: ids) }
    func promptAddTags(to ids: [Int64]) { tagRequest = TagRequest(ids: ids) }

    // MARK: Missing files (plan H2)

    struct MissingRemoval: Identifiable { let id = UUID(); var ids: [Int64]?; var count: Int }
    var missingRemoval: MissingRemoval?

    /// Files marked missing in the current results, or all of them.
    func promptRemoveMissing(ids: [Int64]? = nil) {
        let count = ids?.count ?? Int(stats?.missing ?? 0)
        guard count > 0 else { return }
        missingRemoval = MissingRemoval(ids: ids, count: count)
    }

    func removeMissing(_ removal: MissingRemoval) async {
        do {
            let n = try await handle?.removeMissing(assetIds: removal.ids) ?? 0
            await refreshSidebarData()
            requery()
            selectedIDs = []
            inform(n == 0 ? "Nothing was removed." : "Removed \(n) file\(n == 1 ? "" : "s") from SmartAsset. Your files were not touched.")
        } catch { report(error) }
    }

    /// Looks for missing files in another folder: adding it lets SmartAsset recognise moved files by their content.
    func locateMissingFiles() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Look Here"
        panel.message = "Choose the folder where these files are now. SmartAsset recognises them by their content and adds the folder to your library."
        guard panel.runModal() == .OK else { return }
        await addFolders(panel.urls)
        inform("Looked for missing files in the new folder. Anything it recognised is back in your library.")
    }

    // MARK: Opening files

    /// Paths of selected files whose drive is connected.
    func paths(for ids: [Int64]) async -> [URL] {
        guard let handle, let list = try? await handle.paths(assetIds: ids) else { return [] }
        return list.compactMap { $0.path.map { URL(fileURLWithPath: $0) } }
    }

    func showInFinder(_ ids: [Int64]) async {
        let urls = await paths(for: ids)
        guard !urls.isEmpty else { inform("Plug in the drive to show these files in Finder."); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openWithDefaultApp(_ ids: [Int64]) async {
        for url in await paths(for: ids).prefix(10) { NSWorkspace.shared.open(url) }
    }

    /// What the status bar says.
    var statusText: String {
        if sidebar == .duplicates, let d = duplicates {
            let groups = d.exact.count + d.similar.count
            return "\(groups.formatted()) \(groups == 1 ? "group" : "groups") · \(DuplicateText.freed(d.exactWasted + d.similarWasted))"
        }
        let count = resultCount
        let noun = count == 1 ? "file" : "files"
        var parts = ["\(count.formatted()) \(noun)"]
        if !selectedIDs.isEmpty { parts.append("\(selectedIDs.count.formatted()) selected") }
        return parts.joined(separator: " · ")
    }
}

extension SidebarItem {
    var isCollection: Bool { if case .collection = self { true } else { false } }
}

/// What the menu bar needs to know about the selection (SwiftUI commands do not observe `@Observable`).
final class MenuState: ObservableObject {
    static let shared = MenuState()
    @Published private(set) var selectionCount = 0
    @Published private(set) var onDuplicates = false
    @Published private(set) var tickedCopies = 0
    @Published private(set) var recentSearches = 0
    @Published private(set) var meaningReady = false
    func update(meaningReady value: Bool) { if meaningReady != value { meaningReady = value } }
    func update(recent count: Int) { if recentSearches != count { recentSearches = count } }
    func update(count: Int) { if selectionCount != count { selectionCount = count } }
    func update(onDuplicates value: Bool) { if onDuplicates != value { onDuplicates = value } }
    func update(ticked count: Int) { if tickedCopies != count { tickedCopies = count } }
}

enum Metrics {
    static let thumbMin: Double = 96
    static let thumbMax: Double = 320
    static let thumbDefault: Double = 160
    /// Pictures sit close together, like a gallery: the tile's own 4 pt inset is the only space between them.
    static let cellGap: CGFloat = 0
    static let rowHeight: CGFloat = 32
}

/// Whether search by meaning is usable (Phase 4). The reason, when it is not, is for the person to read.
enum SemanticState: Equatable {
    case loading
    case ready
    /// Not available. `nil` when it was turned off on purpose (no message needed).
    case off(String?)
}

extension SidebarItem {
    /// Typed words rank by best match on these pages unless the person chose an order. A collection keeps the order
    /// its owner arranged, and a smart collection keeps its stored order.
    var ranksTypedSearchByRelevance: Bool {
        switch self {
        case .search, .all, .kind, .folder, .tag: true
        case .missing, .duplicates, .collection, .smart: false
        }
    }
}
