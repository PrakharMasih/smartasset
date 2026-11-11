// The Duplicates page (plan A1, A2): groups on the left, the chosen group's files side by side on the right, one review
// button at the bottom. Looking is read-only. Moving anything starts a review (CleanupSheet); nothing is chosen for you.
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedKey: String?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            content
            if !model.duplicateGroups.isEmpty {
                Divider()
                ActionBar()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Duplicates")
        .task { model.refreshDuplicates() }
        .sheet(item: $model.cleanupReview) { _ in CleanupSheet() }
        .gridArea("duplicates", inset: 0)
    }

    // MARK: Header

    private var header: some View {
        @Bindable var model = model
        let d = model.duplicates
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.md) {
                Picker("Show", selection: $model.duplicateTab) {
                    Text("Exact Copies\(count(d?.exact.count))").tag(DuplicateTab.exact)
                    Text("Similar\(count(d?.similar.count))").tag(DuplicateTab.similar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .accessibilityLabel("Kind of duplicates")
                Spacer(minLength: Space.md)
                Text(DuplicateText.freed(model.duplicateTab == .exact ? (d?.exactWasted ?? 0) : (d?.similarWasted ?? 0)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if model.duplicateTab == .similar {
                Text("Pictures and videos that look alike. Check each group before moving anything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridProbe("duplicates-header", area: "duplicates", edge: nil)
    }

    private func count(_ n: Int?) -> String { n.map { $0 > 0 ? " (\($0.formatted()))" : "" } ?? "" }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let groups = model.duplicateGroups
        if groups.isEmpty {
            EmptyDuplicates()
        } else {
            let current = groups.first { $0.key == selectedKey } ?? groups[0]
            HStack(spacing: 0) {
                List(selection: Binding(get: { current.key }, set: { selectedKey = $0 })) {
                    ForEach(groups, id: \.key) { group in
                        GroupRow(group: group).tag(group.key)
                    }
                }
                .listStyle(.inset)
                .frame(width: 272)
                .accessibilityLabel("Groups")
                .gridProbe("duplicates-list", area: "duplicates", edge: "lead")
                Divider()
                GroupDetail(group: current)
                    .id(current.key)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Select Extra Copies in every group, and the one way to the review.
private struct ActionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let n = model.tickedCount
        HStack(spacing: Space.md) {
            Button("Select Extra Copies in All Groups") { Task { await model.selectExtraCopiesInAllGroups() } }
                .help("Mark every copy except the one SmartAsset would keep, in every group on this tab (nothing moves yet)")
            Spacer(minLength: Space.md)
            Text(n == 0 ? "No copies marked for the Trash" : "\(n.formatted()) \(n == 1 ? "copy" : "copies") marked for the Trash")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(n == 0 ? "Review…" : "Review \(n.formatted()) \(n == 1 ? "Copy" : "Copies")…") {
                Task { await model.reviewTickedCopies() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(n == 0)
            .help("See every marked copy in one list. Nothing moves until you confirm.")
        }
        .controlSize(.regular)
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm + 2)
        .background(.bar)
    }
}

private struct EmptyDuplicates: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.progress
        let comparing = (model.duplicates?.hashRemaining ?? 0) + (model.duplicates?.perceptualRemaining ?? 0)
        VStack(spacing: Space.md) {
            if model.duplicates == nil || model.duplicatesLoading && model.duplicates == nil {
                ProgressView("Looking for duplicates…")
            } else if let hold = p?.hold, comparing > 0 {
                ContentUnavailableView {
                    Label(heldTitle(hold), systemImage: "pause.circle")
                } description: {
                    Text("\(comparing.formatted()) files are waiting to be compared.")
                } actions: {
                    if hold == .user { Button("Resume Indexing") { model.togglePause() } }
                }
            } else if (p?.mediaRemaining ?? 0) > 0 || (p?.scanning ?? false) {
                ContentUnavailableView("Waiting for Indexing to Finish", systemImage: "hourglass",
                                       description: Text("SmartAsset compares files after their thumbnails are made."))
            } else if comparing > 0 {
                ContentUnavailableView {
                    Label("Comparing Files…", systemImage: "square.on.square")
                } description: {
                    Text("\(comparing.formatted()) files left to compare.")
                }
            } else if model.duplicateTab == .exact {
                ContentUnavailableView("No Exact Copies", systemImage: "checkmark.circle",
                                       description: Text("SmartAsset compares files that have the same size, then reads them in full."))
            } else {
                ContentUnavailableView("No Similar Pictures or Videos", systemImage: "checkmark.circle",
                                       description: Text("Plain pictures, such as a black frame, are never compared."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func heldTitle(_ hold: PauseReason) -> String {
        switch hold {
        case .user: "Indexing Is Paused"
        case .battery: "Paused While on Battery"
        case .thermal: "Paused While Your Mac Cools Down"
        case .memory: "Paused: Your Mac Is Low on Memory"
        }
    }
}

// MARK: - One group in the list

private struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroupDto
    @State private var details: [Int64: AssetDetailDto] = [:]

    private var exact: Bool { group.kind == .exact }
    private var marked: Int { model.dupTicks[group.key]?.count ?? 0 }

    private var title: String {
        let kinds = Set(group.members.compactMap { details[$0.assetId]?.summary.kind })
        return DuplicateText.groupTitle(exact: exact, count: group.members.count, kinds: kinds)
    }

    var body: some View {
        HStack(spacing: Space.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill))
                if let first = group.members.first.flatMap({ details[$0.assetId]?.summary }) {
                    ThumbnailImage(id: first.id, rev: first.thumbRev, handle: model.handle)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(DuplicateText.freed(group.wastedBytes)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            if marked > 0 {
                Text("\(marked) marked")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, Space.xs + 2).padding(.vertical, 2)
                    .background(Color.red.opacity(0.14), in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .task(id: group.members.map(\.assetId)) {
            guard let handle = model.handle else { return }
            var found: [Int64: AssetDetailDto] = [:]
            for member in group.members { if let d = try? await handle.assetDetail(assetId: member.assetId) { found[member.assetId] = d } }
            details = found
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(DuplicateText.freed(group.wastedBytes))\(marked > 0 ? ", \(marked) marked for the Trash" : "")")
    }
}

// MARK: - The chosen group

private struct GroupDetail: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroupDto
    @State private var details: [Int64: AssetDetailDto] = [:]

    private var exact: Bool { group.kind == .exact }
    private var memberIDs: [Int64] { group.members.map(\.assetId) }
    private var ticked: Set<Int64> { model.dupTicks[group.key] ?? [] }

    private var copies: [DuplicateTicks.Copy] {
        group.members.map { AppModel.copy($0, online: details[$0.assetId]?.summary.volumeOnline ?? true) }
    }

    private var title: String {
        let kinds = Set(group.members.compactMap { details[$0.assetId]?.summary.kind })
        return DuplicateText.groupTitle(exact: exact, count: group.members.count, kinds: kinds)
    }

    private var subtitle: String {
        var parts: [String] = []
        if exact, let size = details[group.members.first?.assetId ?? 0]?.summary.size { parts.append("\(Format.fileSize(size)) each") }
        parts.append(DuplicateText.freed(group.wastedBytes))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: Space.md)
                Button("Select Extra Copies") { model.selectExtraCopies(in: group, copies: copies) }
                    .controlSize(.small)
                    .help("Mark every copy except the one SmartAsset would keep")
                Button("Clear") { model.clearTicks(in: group.key) }
                    .controlSize(.small)
                    .disabled(ticked.isEmpty)
                    .help("Keep every copy in this group")
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Space.lg) {
                    ForEach(group.members, id: \.assetId) { member in
                        FileCard(member: member, exact: exact, detail: details[member.assetId], group: group, copies: copies)
                    }
                }
                .padding(.bottom, Space.sm)
            }
            .scrollIndicators(.automatic)
            Spacer(minLength: 0)
        }
        .padding(Space.margin)
        .task(id: memberIDs) { await loadDetails() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func loadDetails() async {
        guard let handle = model.handle else { return }
        var found: [Int64: AssetDetailDto] = [:]
        for id in memberIDs { if let d = try? await handle.assetDetail(assetId: id) { found[id] = d } }
        details = found
    }
}

// MARK: - One copy

private struct FileCard: View {
    @Environment(AppModel.self) private var model
    let member: DuplicateMemberDto
    let exact: Bool
    let detail: AssetDetailDto?
    let group: DuplicateGroupDto
    let copies: [DuplicateTicks.Copy]

    private static let width: CGFloat = 248

    private var summary: AssetSummaryDto? { detail?.summary }
    private var online: Bool { summary?.volumeOnline ?? true }
    private var ticked: Set<Int64> { model.dupTicks[group.key] ?? [] }
    private var isTicked: Bool { ticked.contains(member.assetId) }

    private var canTick: Bool {
        guard let me = copies.first(where: { $0.id == member.assetId }) else { return false }
        return DuplicateTicks.canTick(me, in: copies, ticked: ticked)
    }

    /// The folder holding the file, with the home folder shortened: "~/Pictures/Shoot".
    private var location: String {
        guard let path = detail?.path else { return summary.map { "On “\($0.volumeName)”" } ?? "" }
        return (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    // Every card has the same rows in the same order, so the names, matches, sizes and choices line up across the group.
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill))
                if let summary { ThumbnailImage(id: summary.id, rev: summary.thumbRev, handle: model.handle) }
            }
            .frame(width: Self.width - Space.lg, height: 168)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(online ? 1 : 0.5)

            HStack(spacing: Space.xs) {
                Text(summary?.name ?? " ").font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let path = detail?.path, online {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show this file in Finder")
                    .accessibilityLabel("Show \(summary?.name ?? "file") in Finder")
                }
            }
            // Always present, so a suggested copy does not push its neighbours' rows out of line.
            Label("Suggested to keep", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(Palette.accentText)
                .help(DuplicateText.suggestedHelp)
                .opacity(member.suggestedKeep ? 1 : 0)
                .accessibilityHidden(!member.suggestedKeep)
            Text(DuplicateText.match(percent: member.similarity, exact: exact))
                .font(.caption).foregroundStyle(.secondary)
            Text(metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            if online {
                Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(detail?.path ?? "")
            } else if let summary {
                Label("Plug in “\(summary.volumeName)”", systemImage: "powerplug")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(" ").font(.caption)
            }
            Picker("Choice", selection: Binding(get: { isTicked }, set: { model.setTick(member.assetId, $0, in: group.key) })) {
                Text("Keep").tag(false)
                Text("Move to Trash").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .disabled(!canTick)
            .help(online ? (canTick || isTicked ? "Choose Move to Trash to review this copy for the Trash. Nothing moves until you confirm."
                                               : "At least one copy has to stay")
                         : "Plug in “\(summary?.volumeName ?? "its drive")” to move this file.")
            .accessibilityLabel("\(summary?.name ?? "This file"): keep or move to the Trash")
        }
        .frame(width: Self.width, alignment: .leading)
        .padding(Space.sm)
        .background(isTicked ? Color.red.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isTicked ? Color.red.opacity(0.4) : Color.clear))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(voiceOver)
    }

    private var metaLine: String {
        guard let s = summary else { return " " }
        let date = Date(timeIntervalSince1970: Double(s.mtime) / 1000).formatted(date: .abbreviated, time: .omitted)
        return "\(Format.fileSize(s.size)) · \(date)"
    }

    private var voiceOver: String {
        guard let s = summary else { return "File" }
        var parts = [s.name, Format.fileSize(s.size), DuplicateText.match(percent: member.similarity, exact: exact), "in \(location)"]
        if member.suggestedKeep { parts.append("suggested to keep") }
        if !online { parts.append("drive not connected") }
        return parts.joined(separator: ", ")
    }
}

/// A thumbnail from the cache folder, decoded off the main thread.
struct ThumbnailImage: View {
    let id: Int64
    let rev: Int64
    let handle: EngineHandle?
    /// Fill the frame (cropping the edges) instead of fitting the whole picture in it.
    var fill = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .task(id: "\(id)-\(rev)") { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard rev > 0, let path = handle?.thumbPath(assetId: id, rev: rev) else { image = nil; return }
        if let cached = ThumbnailLoader.shared.cached(id: id, rev: rev, bucket: 256) { image = cached; return }
        let id = id, rev = rev
        image = await withCheckedContinuation { continuation in
            ThumbnailLoader.shared.load(id: id, rev: rev, path: path, bucket: 256) { continuation.resume(returning: $0) }
        }
    }
}
