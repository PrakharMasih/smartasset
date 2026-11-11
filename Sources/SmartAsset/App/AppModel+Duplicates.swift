// The Duplicates page and the cleanup flow (plan A1–A3): detection is read-only; cleanup is review, confirm, Trash.
import AppKit
import CoreBridge
import Foundation
import SmartAssetKit

enum DuplicateTab: String, CaseIterable, Identifiable {
    case exact = "Exact Copies"
    case similar = "Similar"
    var id: String { rawValue }
}

/// A review the person is looking at, before anything moves. It covers one group or several; the core checks each
/// group's plan on its own, so a change to one file refuses only what depends on it.
struct CleanupReview: Identifiable {
    enum Phase: Equatable {
        case reviewing
        case working
        /// The core refused (a file changed, a drive left); the text says what to do.
        case refused(String)
    }

    struct Entry {
        var groupKey: String
        var plan: CleanupPlanDto
    }

    let id = UUID()
    var entries: [Entry]
    /// Groups that could not be reviewed, with the reason (a drive is away, a file changed).
    var skipped: [String] = []
    var phase: Phase = .reviewing

    var remove: [CleanupFileDto] { entries.flatMap { $0.plan.remove } }
    var keep: [CleanupFileDto] { entries.flatMap { $0.plan.keep } }
    var bytes: Int64 { entries.reduce(0) { $0 + $1.plan.bytes } }
    var allExact: Bool { entries.allSatisfy { $0.plan.kind == .exact } }
}

/// What a finished cleanup moved, so Undo can put it back.
struct TrashRecord {
    var moved: [Trasher.Moved]
    var bytes: Int64
}

extension CleanupFileDto: Identifiable {
    public var id: Int64 { assetId }
}

extension AppModel {
    // MARK: Groups

    /// Asks the core for the groups. Cheap when nothing changed.
    func refreshDuplicates(after delay: Duration = .zero) {
        duplicatesTask?.cancel()
        duplicatesTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, let handle = self.handle else { return }
            if self.duplicates == nil { self.duplicatesLoading = true }
            defer { self.duplicatesLoading = false }
            guard let fresh = try? await handle.duplicates(), !Task.isCancelled else { return }
            self.duplicates = fresh
            self.pruneTicks(fresh)
        }
    }

    var duplicateGroups: [DuplicateGroupDto] {
        guard let d = duplicates else { return [] }
        return duplicateTab == .exact ? d.exact : d.similar
    }

    /// Ticks that no longer make sense (the group changed or went away) are dropped.
    private func pruneTicks(_ d: DuplicatesDto) {
        var live: [String: DuplicateGroupDto] = [:]
        for g in d.exact + d.similar { live[g.key] = g }
        for (key, ticked) in dupTicks {
            guard let group = live[key] else { dupTicks[key] = nil; continue }
            let kept = DuplicateTicks.pruned(ticked, in: group.members.map { Self.copy($0, online: true) })
            dupTicks[key] = kept.isEmpty ? nil : kept
        }
    }

    static func copy(_ m: DuplicateMemberDto, online: Bool) -> DuplicateTicks.Copy {
        DuplicateTicks.Copy(id: m.assetId, suggestedKeep: m.suggestedKeep, online: online)
    }

    // MARK: Ticking

    func setTick(_ id: Int64, _ on: Bool, in key: String) {
        var set = dupTicks[key] ?? []
        if on { set.insert(id) } else { set.remove(id) }
        dupTicks[key] = set.isEmpty ? nil : set
    }

    func selectExtraCopies(in group: DuplicateGroupDto, copies: [DuplicateTicks.Copy]) {
        let extras = DuplicateTicks.extraCopies(in: copies)
        dupTicks[group.key] = extras.isEmpty ? nil : extras
    }

    func clearTicks(in key: String) { dupTicks[key] = nil }

    /// Total copies ticked, across groups.
    var tickedCount: Int { dupTicks.values.reduce(0) { $0 + $1.count } }

    /// Ticks every copy except the suggested one in every group of the open tab. Files on a drive that is away are
    /// left alone.
    func selectExtraCopiesInAllGroups() async {
        guard let handle else { return }
        let groups = duplicateGroups
        let ids = groups.flatMap { $0.members.map(\.assetId) }
        var online: [Int64: Bool] = [:]
        for start in stride(from: 0, to: ids.count, by: 4_000) {
            let chunk = Array(ids[start..<min(start + 4_000, ids.count)])
            for s in (try? await handle.summaries(assetIds: chunk)) ?? [] { online[s.id] = s.volumeOnline }
        }
        let shown = Set(groups.map(\.key))
        var ticks = dupTicks.filter { !shown.contains($0.key) }
        for g in groups {
            let extras = DuplicateTicks.extraCopies(in: g.members.map { Self.copy($0, online: online[$0.assetId] ?? true) })
            if !extras.isEmpty { ticks[g.key] = extras }
        }
        dupTicks = ticks
    }

    func clearAllTicks() { dupTicks = [:] }

    // MARK: Cleanup: review → confirm → Trash

    /// Step 1 for one group.
    func reviewCleanup(of group: DuplicateGroupDto) async { await reviewTickedCopies(in: [group]) }

    /// Step 1: build the review for the ticked copies of these groups (every ticked group by default). Nothing moves.
    func reviewTickedCopies(in only: [DuplicateGroupDto]? = nil) async {
        guard let handle, let d = duplicates else { return }
        let groups = only ?? (d.exact + d.similar).filter { !(dupTicks[$0.key] ?? []).isEmpty }
        var entries: [CleanupReview.Entry] = []
        var skipped: [String] = []
        for group in groups {
            guard let ticked = dupTicks[group.key], !ticked.isEmpty else { continue }
            do {
                let plan = try await handle.planCleanup(groupKey: group.key, removeIds: group.members.map(\.assetId).filter { ticked.contains($0) })
                entries.append(CleanupReview.Entry(groupKey: group.key, plan: plan))
            } catch {
                skipped.append(error.userMessage)
            }
        }
        guard !entries.isEmpty else {
            if let why = skipped.first { banner = Banner(text: why, style: .warning) }
            refreshDuplicates()
            return
        }
        cleanupReview = CleanupReview(entries: entries, skipped: skipped)
    }

    func cancelCleanupReview() {
        guard let review = cleanupReview, review.phase != .working else { return }
        for e in review.entries { handle?.cancelCleanup(token: e.plan.token) }
        cleanupReview = nil
    }

    /// Steps 2 and 3: the person pressed **Move to Trash**. For each group the core approves the files again against
    /// the disk; only approved files are moved; the core is told what moved. A refusal stops the rest.
    func confirmCleanup() async {
        guard let handle, var review = cleanupReview, review.phase == .reviewing else { return }
        review.phase = .working
        cleanupReview = review
        var moved: [Trasher.Moved] = []
        var failed: [(name: String, reason: String)] = []
        var bytes: Int64 = 0
        var refusal: String?
        var done = 0
        for entry in review.entries {
            do {
                let approved = try await handle.approveCleanup(token: entry.plan.token, confirmedIds: entry.plan.remove.map(\.assetId))
                let outcome = await Trasher.moveToTrash(approved)
                let summary = try await handle.cleanupDone(token: entry.plan.token, trashedIds: outcome.moved.map(\.assetId))
                moved += outcome.moved
                failed += outcome.failed
                bytes += summary.bytes
                dupTicks[entry.groupKey] = nil
                done += 1
            } catch {
                refusal = error.userMessage
                break
            }
        }
        // Reviews that were never confirmed are closed, so no token outlives the sheet.
        for entry in review.entries.dropFirst(done) { handle.cancelCleanup(token: entry.plan.token) }
        finishCleanup(moved: moved, failed: failed, bytes: bytes)
        if let refusal {
            var text = refusal
            if !moved.isEmpty { text += " \(moved.count) \(moved.count == 1 ? "file was" : "files were") already moved to the Trash; Undo puts \(moved.count == 1 ? "it" : "them") back." }
            review.phase = .refused(text)
            // Only the work that did not happen stays in the review.
            review.entries = Array(review.entries.dropFirst(done))
            cleanupReview = review
        } else {
            cleanupReview = nil
        }
    }

    private func finishCleanup(moved: [Trasher.Moved], failed: [(name: String, reason: String)], bytes: Int64) {
        refreshDuplicates()
        Task { await refreshSidebarData() }
        requery()
        guard !moved.isEmpty else {
            if !failed.isEmpty {
                let why = failed.first.map { " “\($0.name)”: \($0.reason)" } ?? ""
                banner = Banner(text: "Nothing was moved to the Trash.\(why)", style: .warning)
            }
            return
        }
        lastTrash = TrashRecord(moved: moved, bytes: bytes)
        var text = DuplicateText.trashed(count: moved.count, bytes: bytes)
        if !failed.isEmpty { text += " \(failed.count) could not be moved and stayed where they were." }
        let b = Banner(text: text, style: failed.isEmpty ? .info : .warning, actionTitle: "Undo", action: .undoTrash)
        banner = b
        registerUndo("Move to Trash") { [weak self] in await self?.undoLastTrash() }
        Task {
            try? await Task.sleep(for: .seconds(12))
            if banner?.id == b.id { banner = nil }
        }
    }

    /// Puts the last cleanup's files back where they were and lets the library find them again.
    func undoLastTrash() async {
        guard let record = lastTrash else { return }
        lastTrash = nil
        let result = Trasher.restore(record.moved)
        try? await handle?.rescan(folderId: nil)
        refreshDuplicates(after: .seconds(1))
        if result.kept.isEmpty {
            inform("Put \(result.restored) \(result.restored == 1 ? "file" : "files") back.")
        } else {
            banner = Banner(text: "Put \(result.restored) back. \(result.kept.joined(separator: ", ")) could not be put back; use Put Back in the Trash.", style: .warning)
        }
    }

    func showTrash() {
        NSWorkspace.shared.open(URL.homeDirectory.appending(path: ".Trash", directoryHint: .isDirectory))
    }
}
