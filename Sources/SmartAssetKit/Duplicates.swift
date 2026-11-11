// The rules and the words of the Duplicates page (plan A1–A3). Pure; no UI, no bridge calls, so every rule is tested.
import CoreBridge
import Foundation

/// What a person may tick in a group, and what "Select Extra Copies" picks.
public enum DuplicateTicks {
    /// One copy in a group as the page sees it.
    public struct Copy: Hashable, Sendable {
        public let id: Int64
        public let suggestedKeep: Bool
        /// False while the file's drive is not connected: it cannot be moved.
        public let online: Bool

        public init(id: Int64, suggestedKeep: Bool, online: Bool) {
            self.id = id
            self.suggestedKeep = suggestedKeep
            self.online = online
        }
    }

    /// A copy can be ticked when its drive is connected and at least one other copy would stay un-ticked.
    /// Ticking every copy would lose the file, so the last box is switched off.
    public static func canTick(_ copy: Copy, in group: [Copy], ticked: Set<Int64>) -> Bool {
        guard copy.online else { return false }
        if ticked.contains(copy.id) { return true }  // an existing tick can always be removed
        let staying = group.filter { !ticked.contains($0.id) && $0.id != copy.id }
        return !staying.isEmpty
    }

    /// Every copy except the suggested one, skipping files that cannot be moved.
    public static func extraCopies(in group: [Copy]) -> Set<Int64> {
        let keeper = group.first { $0.suggestedKeep } ?? group.first
        return Set(group.filter { $0.id != keeper?.id && $0.online }.map(\.id))
    }

    /// Drops ticks that are no longer allowed after a group changed (a file left it, a drive went away).
    public static func pruned(_ ticked: Set<Int64>, in group: [Copy]) -> Set<Int64> {
        let movable = Set(group.filter(\.online).map(\.id))
        var kept = ticked.intersection(movable)
        if kept.count >= group.count, let first = group.first { kept.remove(first.id) }
        return kept
    }
}

/// Words, so every string on the page comes from one place and uses the glossary's terms.
public enum DuplicateText {
    /// "3 exact copies" · "3 similar photos" · "2 similar videos" · "4 similar files".
    public static func groupTitle(exact: Bool, count: Int, kinds: Set<MediaKind>) -> String {
        if exact { return "\(count) exact copies" }
        if kinds == [.image] { return "\(count) similar photos" }
        if kinds == [.video] { return "\(count) similar videos" }
        return "\(count) similar files"
    }

    /// "18.4 GB could be freed", or "Nothing to free" for an empty total.
    public static func freed(_ bytes: Int64) -> String {
        bytes > 0 ? "\(Format.fileSize(bytes)) could be freed" : "Nothing to free"
    }

    /// "Exact copy" or "94% match".
    public static func match(percent: UInt8, exact: Bool) -> String {
        exact ? "Exact copy" : "\(percent)% match"
    }

    /// "Move 1 File to the Trash?" / "Move 3 Files to the Trash?"
    public static func reviewTitle(count: Int) -> String {
        "Move \(count) \(count == 1 ? "File" : "Files") to the Trash?"
    }

    /// The button that opens the review: "Move 2 Files to the Trash…".
    public static func reviewButton(count: Int) -> String {
        if count == 0 { return "Move to Trash…" }
        return "Move \(count) \(count == 1 ? "File" : "Files") to the Trash…"
    }

    /// "Moved 2 files to the Trash (24 MB)."
    public static func trashed(count: Int, bytes: Int64) -> String {
        "Moved \(count) \(count == 1 ? "file" : "files") to the Trash (\(Format.fileSize(bytes)))."
    }

    /// The tooltip on the suggested copy.
    public static let suggestedHelp =
        "SmartAsset would keep this one: it has your ratings or tags, otherwise it is the sharpest, then the oldest."

    /// The line under the file list in the review.
    public static let mergeNote = "Ratings, tags and collections on these files move to the file that stays."
}
