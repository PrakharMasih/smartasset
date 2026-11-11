// Moving files to the Trash, and putting them back (plan A3).
//
// This is the only place in SmartAsset that moves a user's file. It acts only on `ApprovedTrashDto` values, which the
// Rust core hands out after it has checked each file against the disk (core `cleanup.rs`); nothing else can reach it.
// Files go to the Trash with the system call Finder uses, so "Put Back" and Undo both work. They are never deleted.
import AppKit
import CoreBridge
import Foundation

enum Trasher {
    struct Moved: Sendable {
        let assetId: Int64
        let original: URL
        let trashed: URL
    }

    struct Outcome: Sendable {
        var moved: [Moved] = []
        /// File name and the reason it stayed where it was.
        var failed: [(name: String, reason: String)] = []
    }

    /// Moves each approved file to the Trash, one at a time so a failure is pinned on its file.
    static func moveToTrash(_ approved: [ApprovedTrashDto]) async -> Outcome {
        var outcome = Outcome()
        for item in approved {
            let url = URL(fileURLWithPath: item.path)
            let (trashed, failure) = await recycle(url)
            if let trashed {
                outcome.moved.append(Moved(assetId: item.assetId, original: url, trashed: trashed))
            } else {
                outcome.failed.append((url.lastPathComponent, failure ?? "macOS could not move it to the Trash."))
            }
        }
        return outcome
    }

    private static func recycle(_ url: URL) async -> (URL?, String?) {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { newURLs, error in
                continuation.resume(returning: (newURLs[url] ?? newURLs.values.first, error?.localizedDescription))
            }
        }
    }

    /// Puts files back where they were, unless something else is there now. Returns how many came back.
    static func restore(_ moved: [Moved]) -> (restored: Int, kept: [String]) {
        let fm = FileManager.default
        var restored = 0
        var kept: [String] = []
        for item in moved {
            guard fm.fileExists(atPath: item.trashed.path) else { kept.append(item.original.lastPathComponent); continue }
            guard !fm.fileExists(atPath: item.original.path) else { kept.append(item.original.lastPathComponent); continue }
            do {
                try fm.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: item.trashed, to: item.original)
                restored += 1
            } catch {
                kept.append(item.original.lastPathComponent)
            }
        }
        return (restored, kept)
    }
}
