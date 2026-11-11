// Combining the sidebar's place with the chips the person added. Pure logic, tested without the app.
import CoreBridge
import Foundation

public extension Filters {
    /// No condition at all.
    static var none: Filters { SearchQuery.everything.filters }

    /// `self` (what the person added with chips) laid over `base` (what the sidebar page implies).
    /// A kind, orientation or label chosen with chips replaces the page's; required tags add up; single values win.
    func merged(over base: Filters) -> Filters {
        var out = base
        if !kinds.isEmpty { out.kinds = kinds }
        if let date { out.date = date }
        if let minDurationMs { out.minDurationMs = minDurationMs }
        if let maxDurationMs { out.maxDurationMs = maxDurationMs }
        if let minResolution { out.minResolution = minResolution }
        if !orientations.isEmpty { out.orientations = orientations }
        for tag in tagsAll where !out.tagsAll.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            out.tagsAll.append(tag)
        }
        if !tagsAny.isEmpty { out.tagsAny = tagsAny }
        if let minRating { out.minRating = minRating }
        if unratedOnly { out.unratedOnly = true }
        if let flag { out.flag = flag }
        if !colorLabels.isEmpty { out.colorLabels = colorLabels }
        if !folderIds.isEmpty { out.folderIds = folderIds }
        if !volumeIds.isEmpty { out.volumeIds = volumeIds }
        if let collectionId { out.collectionId = collectionId }
        if missing != .hide { out.missing = missing }
        return out
    }

    /// True when no condition is set.
    var isEmpty: Bool { self == Filters.none }
}

/// A page of the sidebar.
public enum SidebarItem: Hashable, Sendable {
    /// The Search page (plan S1, S12, S13): the start page. Describe what you want; matches fill the grid.
    case search
    case all
    case kind(MediaKind)
    case missing
    /// Copies and look-alikes (plan A1, A2). Not a search: it has its own page.
    case duplicates
    case folder(Int64)
    case collection(Int64)
    case smart(Int64)
    case tag(String)

    /// Stable text form, for remembering the selection between launches.
    public var storageKey: String {
        switch self {
        case .search: "search"
        case .all: "all"
        case .kind(.image): "kind:image"
        case .kind(.video): "kind:video"
        case .kind(.audio): "kind:audio"
        case .missing: "missing"
        case .duplicates: "duplicates"
        case .folder(let id): "folder:\(id)"
        case .collection(let id): "collection:\(id)"
        case .smart(let id): "smart:\(id)"
        case .tag(let name): "tag:\(name)"
        }
    }

    public init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("search", _): self = .search
        case ("all", _): self = .all
        case ("missing", _): self = .missing
        case ("duplicates", _): self = .duplicates
        case ("kind", "image"): self = .kind(.image)
        case ("kind", "video"): self = .kind(.video)
        case ("kind", "audio"): self = .kind(.audio)
        case ("folder", let id?): guard let v = Int64(id) else { return nil }; self = .folder(v)
        case ("collection", let id?): guard let v = Int64(id) else { return nil }; self = .collection(v)
        case ("smart", let id?): guard let v = Int64(id) else { return nil }; self = .smart(v)
        case ("tag", let name?): self = .tag(name)
        default: return nil
        }
    }

    /// The conditions this page implies. `smart` pages are resolved by the caller from the stored query.
    public func baseFilters() -> Filters {
        var f = Filters.none
        switch self {
        case .all, .smart, .duplicates, .search: break
        case .kind(let k): f.kinds = [k]
        case .missing: f.missing = .only
        case .folder(let id): f.folderIds = [id]
        case .collection(let id): f.collectionId = id
        case .tag(let name): f.tagsAll = [name]
        }
        return f
    }
}

/// How the result is ordered, as people name it.
public struct SortChoice: Hashable, Sendable, Identifiable {
    public let key: SortKey
    public let descending: Bool
    public var id: String { "\(key)-\(descending)" }

    public init(key: SortKey, descending: Bool) {
        self.key = key
        self.descending = descending
    }

    public static let newest = SortChoice(key: .dateCaptured, descending: true)
    public static let oldest = SortChoice(key: .dateCaptured, descending: false)
    /// The Search page's own order: the files that answer the words best come first.
    public static let bestMatch = SortChoice(key: .relevance, descending: false)

    public var sort: Sort { Sort(key: key, descending: descending) }

    public var title: String {
        switch (key, descending) {
        case (.dateCaptured, true): "Date (Newest First)"
        case (.dateCaptured, false): "Date (Oldest First)"
        case (.dateAdded, true): "Date Added (Newest First)"
        case (.dateAdded, false): "Date Added (Oldest First)"
        case (.dateModified, true): "Date Modified (Newest First)"
        case (.dateModified, false): "Date Modified (Oldest First)"
        case (.name, false): "Name (A–Z)"
        case (.name, true): "Name (Z–A)"
        case (.size, true): "Size (Largest First)"
        case (.size, false): "Size (Smallest First)"
        case (.duration, true): "Duration (Longest First)"
        case (.duration, false): "Duration (Shortest First)"
        case (.rating, true): "Rating (Highest First)"
        case (.rating, false): "Rating (Lowest First)"
        case (.kind, _): "Kind"
        case (.relevance, _): "Best Match"
        case (.manual, _): "Manual Order"
        }
    }

    public static let menu: [SortChoice] = [
        .newest, .oldest,
        SortChoice(key: .name, descending: false), SortChoice(key: .name, descending: true),
        SortChoice(key: .rating, descending: true),
        SortChoice(key: .size, descending: true), SortChoice(key: .size, descending: false),
        SortChoice(key: .duration, descending: true),
        SortChoice(key: .dateAdded, descending: true),
        SortChoice(key: .kind, descending: false),
    ]
}

/// Plain-language descriptions of the active conditions, for the chips.
public enum FilterText {
    public static func chips(for f: Filters) -> [(id: String, title: String)] {
        var out: [(String, String)] = []
        for kind in f.kinds { out.append(("kind:\(kind.label)", kind.label + "s")) }
        for o in f.orientations { out.append(("orient:\(o)", orientation(o))) }
        if let r = f.minResolution { out.append(("res", resolution(r))) }
        if f.minDurationMs != nil || f.maxDurationMs != nil { out.append(("duration", duration(min: f.minDurationMs, max: f.maxDurationMs))) }
        if f.date != nil { out.append(("date", "Date")) }
        if f.unratedOnly { out.append(("unrated", "Unrated")) } else if let r = f.minRating, r > 0 { out.append(("rating", String(repeating: "★", count: Int(r)) + " & up")) }
        if let flag = f.flag, flag != .none { out.append(("flag", flag == .pick ? "Picks" : "Rejects")) }
        for c in f.colorLabels { out.append(("label:\(c)", "\(colorName(c)) Label")) }
        for t in f.tagsAll { out.append(("tag:\(t)", "#\(t)")) }
        return out
    }

    public static func orientation(_ o: Orientation) -> String {
        switch o { case .horizontal: "Horizontal"; case .vertical: "Vertical"; case .square: "Square" }
    }

    public static func resolution(_ r: ResolutionClass) -> String {
        switch r { case .hd720: "720p+"; case .fhd1080: "1080p+"; case .qhd1440: "1440p+"; case .uhd4k: "4K+"; case .uhd8k: "8K" }
    }

    public static func duration(min: Int64?, max: Int64?) -> String {
        switch (min, max) {
        case (nil, let hi?): "Under \(Format.duration(milliseconds: hi))"
        case (let lo?, nil): "Over \(Format.duration(milliseconds: lo))"
        case (let lo?, let hi?): "\(Format.duration(milliseconds: lo))–\(Format.duration(milliseconds: hi))"
        default: "Duration"
        }
    }

    public static func colorName(_ c: ColorLabel) -> String {
        switch c {
        case .none: "None"; case .red: "Red"; case .orange: "Orange"; case .yellow: "Yellow"
        case .green: "Green"; case .blue: "Blue"; case .purple: "Purple"; case .gray: "Gray"
        }
    }
}

/// Where the Search page looks. "Everywhere" is the whole library; the others narrow it to one place (the "in …" chip).
public enum SearchScope: Hashable, Sendable {
    case everywhere
    case folder(Int64)
    case collection(Int64)
    case tag(String)

    /// The conditions this scope adds to a search.
    public var filters: Filters {
        var f = Filters.none
        switch self {
        case .everywhere: break
        case .folder(let id): f.folderIds = [id]
        case .collection(let id): f.collectionId = id
        case .tag(let name): f.tagsAll = [name]
        }
        return f
    }

    /// The scope a library page implies, for the magnifier button ("Search in Iceland Trip").
    public init(page: SidebarItem) {
        switch page {
        case .folder(let id): self = .folder(id)
        case .collection(let id): self = .collection(id)
        case .tag(let name): self = .tag(name)
        default: self = .everywhere
        }
    }
}

/// The last searches, newest first, without repeats. Pure; the app stores the list on this Mac only.
public struct RecentSearches: Equatable, Sendable {
    public static let limit = 10
    public private(set) var items: [String]

    public init(_ items: [String] = []) { self.items = Array(items.prefix(Self.limit)) }

    /// Puts `text` first. Blank text and one-letter words are not worth remembering; the same words in another case replace the old entry.
    public mutating func add(_ text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count >= 2 else { return }
        items.removeAll { $0.caseInsensitiveCompare(words) == .orderedSame }
        items.insert(words, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    public mutating func remove(_ text: String) { items.removeAll { $0 == text } }
    public mutating func clear() { items = [] }
}


/// The words a picture can show as labels (C1): single, everyday creator subjects. Single words because the cut-off was
/// measured on single words. Changing the list changes no stored data: labels are worked out from the vectors when asked.
public enum LabelWords {
    public static let all = [
        "beach", "mountain", "forest", "city", "street", "building", "sunset", "snow", "water", "desert",
        "food", "kitchen", "office", "stage", "crowd", "people", "portrait", "child", "dog", "cat",
        "bird", "horse", "car", "bicycle", "boat", "airplane", "train", "laptop", "flowers", "garden",
        "road", "sports", "night",
    ]
}
