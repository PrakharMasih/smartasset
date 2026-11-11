// A window onto a result set that lives in Rust: only the pages on screen are ever fetched (plan V1).
import AppKit
import CoreBridge
import Foundation

@MainActor
final class PagedSource {
    static let pageSize = 160

    let results: ResultSet
    let count: Int
    private let handle: EngineHandle
    private var pages: [Int: [AssetSummaryDto]] = [:]
    private var pathsByID: [Int64: URL] = [:]
    private var loading: Set<Int> = []
    /// S2: the search and its vector, when results came from search by meaning; each page then asks for its videos' moments.
    private let momentsFor: (query: SearchQuery, vector: [Float])?
    private var momentByID: [Int64: Int64] = [:]
    /// Called with the range of positions whose data just arrived.
    var onLoaded: ((Range<Int>) -> Void)?

    init(results: ResultSet, handle: EngineHandle, momentsFor: (query: SearchQuery, vector: [Float])? = nil) {
        self.results = results
        self.handle = handle
        self.momentsFor = momentsFor
        self.count = Int(results.count())
    }

    func summary(at index: Int) -> AssetSummaryDto? {
        guard index >= 0, index < count else { return nil }
        let page = pages[index / Self.pageSize]
        let offset = index % Self.pageSize
        return page.flatMap { offset < $0.count ? $0[offset] : nil }
    }

    func id(at index: Int) -> Int64? {
        guard index >= 0, index < count else { return nil }
        return results.idAt(index: UInt64(index))
    }

    func path(for id: Int64) -> URL? { pathsByID[id] }

    /// Where in this video the search matched best (milliseconds), if search by meaning added it.
    func moment(for id: Int64) -> Int64? { momentByID[id] }

    /// Starts fetching every page that touches `range`, plus one page of lookahead each way.
    func ensure(_ range: Range<Int>) {
        guard count > 0, !range.isEmpty else { return }
        let first = max(0, range.lowerBound / Self.pageSize - 1)
        let last = min((count - 1) / Self.pageSize, (range.upperBound - 1) / Self.pageSize + 1)
        guard first <= last else { return }
        for page in first...last where pages[page] == nil && !loading.contains(page) { fetch(page) }
    }

    /// Fetches the visible pages again (a thumbnail arrived) while keeping the old data on screen.
    func refresh(_ range: Range<Int>) {
        guard count > 0, !range.isEmpty else { return }
        let first = range.lowerBound / Self.pageSize
        let last = min((count - 1) / Self.pageSize, (range.upperBound - 1) / Self.pageSize)
        for page in first...last where !loading.contains(page) { fetch(page) }
        // Pages far from the screen are dropped to keep memory flat.
        for key in pages.keys where key < first - 4 || key > last + 4 { pages.removeValue(forKey: key) }
    }

    private func fetch(_ page: Int) {
        loading.insert(page)
        let offset = UInt64(page * Self.pageSize)
        let limit = UInt64(Self.pageSize)
        Task { [weak self] in
            guard let self else { return }
            defer { self.loading.remove(page) }
            do {
                let items = try await self.results.summaries(offset: offset, limit: limit)
                // Paths for drag-out, Quick Look and Show in Finder come with the page.
                let paths = (try? await self.handle.paths(assetIds: items.map(\.id))) ?? []
                for entry in paths { if let p = entry.path { self.pathsByID[entry.assetId] = URL(fileURLWithPath: p) } else { self.pathsByID.removeValue(forKey: entry.assetId) } }
                if let momentsFor = self.momentsFor {
                    let videos = items.filter { $0.kind == .video }.map(\.id)
                    if !videos.isEmpty, let found = try? await self.handle.moments(query: momentsFor.query, vector: momentsFor.vector, assetIds: videos) {
                        for m in found { self.momentByID[m.assetId] = m.momentMs }
                    }
                }
                self.pages[page] = items
                let start = page * Self.pageSize
                self.onLoaded?(start..<min(self.count, start + items.count))
            } catch {
                // The result set was replaced or the engine is closing: the next query brings fresh pages.
            }
        }
    }
}
