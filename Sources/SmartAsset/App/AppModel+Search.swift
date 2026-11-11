// The Search page: opening it, its scope and recent searches, and how ready search by meaning is (UX block in docs/STORIES.md, S13).
import AppKit
import CoreBridge
import Embedding
import SmartAssetKit
import Workers

/// What the Search page tells people about search by meaning, in the words it shows.
enum SearchReadiness: Equatable {
    /// The model is loading.
    case loading
    /// Meaning and words both work; every file has been read.
    case ready
    /// Meaning works, but `left` files have not been read yet, so a match may be missing.
    case preparing(left: Int)
    /// Words only. `reason` is the sentence to show when the model failed rather than being turned off.
    case wordsOnly(reason: String?)
}

extension AppModel {
    /// Shows the Search page with the cursor in its field. ⌘F and ⌘K from anywhere, the Search row, the magnifier button.
    /// `scope` narrows it ("Search in Iceland Trip"); without one a search starts everywhere.
    func openSearch(scope: SearchScope? = nil) {
        // From the Viewer or Settings: bring the library window forward, because the page is in it.
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.lowercased().contains("main") == true && $0.canBecomeKey }),
           !main.isKeyWindow {
            main.makeKeyAndOrderFront(nil)
        }
        if let scope {
            searchScope = scope
        } else if sidebar != .search {
            searchScope = .everywhere
        }
        sidebar = .search
        searchFocusRequest += 1
    }

    /// The magnifier button on a library page: search inside what the page shows.
    func openSearchInCurrentPage() {
        openSearch(scope: SearchScope(page: sidebar))
    }

    /// Remembers what was searched once the person acts on it (Return, or opening a result).
    func commitSearch() {
        recentSearches.add(searchText)
    }

    /// A recent search or an example: fill the field and ask.
    func search(for words: String) {
        searchText = words
        commitSearch()
        searchFocusRequest += 1
    }

    /// Clears the words and the scope, and puts the cursor back in the field.
    func newSearch() {
        searchText = ""
        searchScope = .everywhere
        filters = Filters.none
        searchFocusRequest += 1
    }

    /// Words typed on the Search page (blank counts as none).
    var hasSearchWords: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The Search page shows results: it has words, or a file to find more like.
    var searchHasQuestion: Bool { hasSearchWords || searchLike != nil }

    /// More Like This (S7): shows the files that look like this one on the Search page. Needs search by meaning.
    func moreLikeThis(_ id: Int64) async {
        guard semantic == .ready, let handle else {
            inform("More Like This needs search by meaning, which is not ready yet.")
            return
        }
        guard let summary = try? await handle.summaries(assetIds: [id]).first else { return }
        guard summary.kind != .audio else {
            inform("Sounds can’t be searched by what they look like yet.")
            return
        }
        searchText = ""
        searchLike = LikeTarget(id: id, name: summary.name)
        openSearch()
    }

    /// A label chip in the Inspector: search the whole library for that word.
    func searchLabel(_ word: String) {
        searchLike = nil
        openSearch(scope: .everywhere)
        search(for: word)
    }

    /// Ends More Like This and puts the cursor back in the field.
    func clearLike() {
        searchLike = nil
        searchFocusRequest += 1
    }

    /// Why a file came up for what is on the Search page (S11): where each word was found, and how close it is by meaning.
    func explainMatch(_ id: Int64) async -> MatchExplanationDto? {
        guard sidebar == .search, hasSearchWords, let handle else { return nil }
        let words = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let vector = await queryVector(words)
        return try? await handle.explainMatch(assetId: id, query: currentQuery, vector: vector)
    }

    /// The page lists files (grid or list) and has details to show: everything except Duplicates and the Search home.
    var showsResults: Bool {
        switch sidebar {
        case .duplicates: false
        case .search: searchHasQuestion
        default: true
        }
    }

    /// The All · Images · Videos · Audio bar sits over every page of files, and over Search results.
    var showsKindScope: Bool {
        switch sidebar {
        case .duplicates, .missing, .search: false
        default: true
        }
    }

    /// Chips and "Save as Smart Collection…" show when there is something to keep or clear (the kind has its own bar).
    var showsFilterBar: Bool {
        guard sidebar != .duplicates, sidebar != .search else { return false }
        var rest = filters
        rest.kinds = []
        return hasSearchWords || !rest.isEmpty
    }

    var searchReadiness: SearchReadiness {
        switch semantic {
        case .loading: .loading
        case .off(let reason): .wordsOnly(reason: reason)
        case .ready:
            if let left = progress?.embedRemaining, left > 0 { .preparing(left: Int(left)) } else { .ready }
        }
    }

    /// Tooltip of the magnifier button on a library page.
    var searchHelp: String {
        let scope = SearchScope(page: sidebar)
        return scope == .everywhere ? "Search your library (⌘F)" : "Search in \(scopeName(scope)) (⌘F)"
    }

    /// The name of the scope for the "in …" chip.
    var searchScopeName: String { scopeName(searchScope) }

    func scopeName(_ scope: SearchScope) -> String {
        switch scope {
        case .everywhere: "Everywhere"
        case .folder(let id): folders.first { $0.id == id }?.displayName ?? "Folder"
        case .collection(let id): collections.first { $0.id == id }?.name ?? "Collection"
        case .tag(let name): "#\(name)"
        }
    }
}

extension AppModel {
    /// Loads the search model in the background and, once it is ready, tells the engine and starts making vectors.
    /// Browsing, keyword search and indexing never wait for it, and a model that fails to load costs nothing else.
    func startSemanticSearch(_ engine: CoreEngine) {
        guard !SemanticModels.isDisabled else { semantic = .off(nil); return }
        semantic = .loading
        semanticLoad = Task { [weak self] in
            do {
                let model = try await SemanticModels.load()
                guard let self, !self.isShutDown else { return }
                try await engine.handle.setEmbeddingConfig(config: model.config)
                self.embeddingModel = model
                // C1: the label words, embedded once by this model (about 33 short questions).
                if let cut = model.labelMatch {
                    var vectors: [[Float]] = []
                    for word in LabelWords.all { vectors.append((try? await model.embed(query: word)) ?? []) }
                    engine.handle.setLabels(names: LabelWords.all, vectors: vectors, cut: cut)
                }
                let worker = EmbeddingWorker(engine: engine.handle, events: engine.events, model: model)
                worker.start()
                self.embeddingWorker = worker
                self.semantic = .ready
                // Words typed while the model was loading are answered again, now with meaning.
                self.requery()
            } catch let known as SemanticModelError {
                if case .disabled = known { self?.semantic = .off(nil) } else { self?.semantic = .off(known.errorDescription) }
            } catch {
                self?.semantic = .off(error.userMessage)
            }
        }
    }

    /// The model was removed: stop describing files and searching by meaning; words keep working.
    func stopSemanticSearch() async {
        await embeddingWorker?.stop()
        embeddingWorker = nil
        await semanticLoad?.value
        await embeddingModel?.close()
        embeddingModel = nil
        handle?.clearEmbeddingConfig()
        semantic = .off(SemanticModelError.filesMissing(SemanticModels.modelsRoot).errorDescription)
    }

    /// The words as the model reads a search; empty when there is no model (the answer is then the keyword search).
    func queryVector(_ words: String) async -> [Float] {
        guard semantic == .ready, let model = embeddingModel else { return [] }
        return (try? await model.embed(query: words)) ?? []
    }

    /// What to give the engine along with a typed question: the vector of its words, or nothing.
    func meaning(of question: SearchQuery) async -> [Float] {
        guard let words = question.text, question.sort.key == .relevance else { return [] }
        return await queryVector(words)
    }
}
